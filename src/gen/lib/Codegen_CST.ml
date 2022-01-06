(*
   Code generator for the CST.ml file.
*)

open Printf
open CST_grammar
open Codegen_util

module E = Easy_format

let comment = Codegen_util.comment
let trans = translate_ident

(* Format ocaml type definitions. Might be reusable. *)
module Fmt = struct
  module Style = struct
    open Easy_format

    (* vertical sequence of items,
       intended to be used without parentheses or separators. *)
    let vert_seq = {
      list with
      wrap_body = `Force_breaks;
      indent_body = 0;
      align_closing = false;
      space_after_opening = false;
      space_before_closing = false
    }

    (* style suitable to use with parens and commas *)
    let paren_list = {
      list with
      align_closing = false;
      space_after_opening = false;
      space_before_closing = false
    }

    let horiz_sequence = {
      list with
      wrap_body = `No_breaks;
      stick_to_label = false;
      space_after_opening = false;
      space_before_closing = false
    }

    (* style suitable for polymorphic variants *)
    let left_sep_list = {
      list with
      separators_stick_left = false;
      space_before_separator = true;
      space_after_separator = true
    }

    (* style suitable for classic variants and products *)
    let left_sep_paren_list = {
      left_sep_list with
      space_after_opening = false;
      space_before_closing = false
    }
  end

  let atom s = E.Atom (s, E.atom)

  (* something followed by something else that gets indented if it doesn't
     fit on the same line. *)
  let label lhs rhs = E.Label ((lhs, E.label), rhs)

  let def lhs rhs =
    label (atom lhs) rhs

  let type_app param type_name =
    label param (atom type_name)

  let product l =
    match l with
    | [x] -> x
    | l -> E.List (("(", "*", ")", Style.left_sep_paren_list), l)

  let classic_variant l =
    let cases =
      List.map (fun (name, opt_arg) ->
        match opt_arg with
        | None -> atom name
        | Some arg -> label (atom (name ^ " of")) arg
      ) l
    in
    E.List (("", "|", "", Style.left_sep_paren_list), cases)

  let poly_variant l =
    let cases =
      List.map (fun (name, opt_arg) ->
        match opt_arg with
        | None -> atom ("`" ^ name)
        | Some arg -> label (atom ("`" ^ name ^ " of")) arg
      ) l
    in
    E.List (("[", "|", "]", Style.left_sep_list), cases)

  let record l =
    let fields =
      List.map (fun (name, type_) ->
        E.Label (
          (atom name, E.label),
          type_
        )
      ) l
    in
    E.List (("{", ";", "}", E.list), fields)

  let top_sequence l =
    E.List (("", "", "", Style.vert_seq), l)

  let typedef pos (name, inlined, rhs) =
    let is_first = (pos = 0) in
    let type_ =
      if is_first then
        "type"
      else
        "and"
    in
    let comment =
      if inlined then " (* inlined *)"
      else ""
    in
    let code = def (sprintf "%s %s%s =" type_ name comment) rhs in
    if is_first then code
    else
      top_sequence [
        atom "";
        code
      ]

  (* Insert the correct 'type' or 'and' from a list of OCaml
     type definitions.
  *)
  let recursive_typedefs defs =
    List.mapi typedef defs
    |> top_sequence

end

let preamble grammar =
  sprintf "\
(* Generated by ocaml-tree-sitter. *)
(*
   %s grammar

   entrypoint: %s
*)

open! Sexplib.Conv
open Tree_sitter_run

"
    grammar.name
    grammar.entrypoint

let format_token ~def_name (tok : token) =
  let name = tok.name in
  let interesting_name =
    match def_name with
    | Some rule_name when name = rule_name -> None
    | _ -> Some (trans name)
  in
  let type_ =
    if tok.is_inlined then
      match tok.description with
      | Constant cst ->
          sprintf "Token.t (* %S *)" cst
      | Pattern pat ->
          let pat_str = comment pat in
          sprintf "Token.t (* %spattern %s *)"
            (match interesting_name with
             | None -> ""
             | Some s -> comment s ^ " ")
            pat_str
      | Token
      | External ->
          sprintf "Token.t%s"
            (match interesting_name with
             | None -> ""
             | Some s -> sprintf " (* %s *)" (comment s))
    else
      sprintf "%s (*tok*)" (trans name)
  in
  Fmt.atom type_

let rec format_body ?def_name body : E.t =
  match body with
  | Symbol ident ->
      Fmt.atom (trans ident)
  | Token tok ->
      format_token ~def_name tok
  | Blank ->
      Fmt.atom "unit (* blank *)"
  | Repeat body ->
      Fmt.type_app (format_body body) "list (* zero or more *)"
  | Repeat1 body ->
      Fmt.type_app (format_body body) "list (* one or more *)"
  | Choice case_list ->
      Fmt.poly_variant (format_choice case_list)
  | Optional body ->
      Fmt.type_app (format_body body) "option"
  | Seq body_list ->
      Fmt.product (format_seq body_list)

and format_choice l =
  List.map (fun (name, body) ->
    (name, Some (format_body body))
  ) l

and format_seq l =
  List.map format_body l

let format_rule (rule : rule) =
  (trans rule.name,
   rule.is_inlined_type,
   format_body ~def_name:rule.name rule.body)

let ppx =
  Fmt.top_sequence [
    Fmt.atom "[@@deriving sexp_of]";
    Fmt.atom ""
  ]

(*
   1. Identify names that are used at most once, becoming candidates
      for inlining.
   2. Format the right-hand side of type definitions, replacing
      some type names with their value (inlining).
   3. Move the type definitions that are unused to the bottom of the file
      since they're not useful to the human reader. We keep them so they
      can be used as type annotations by the generated parsers.
*)
let format_types grammar =
  let grammar = Nice_typedefs.rearrange_rules grammar in
  let semi_formatted_defs =
    List.map (fun rule_group ->
      List.map format_rule rule_group
    ) grammar.rules
  in
  List.map (fun def_group ->
    Fmt.top_sequence [
      Fmt.recursive_typedefs def_group;
      ppx
    ]
  ) semi_formatted_defs
  |> Fmt.top_sequence

let generate_dumper grammar =
  sprintf "\

let dump_tree root =
  sexp_of_%s root
  |> Print_sexp.to_stdout
"
    (trans grammar.entrypoint)

let generate grammar =
  let buf = Buffer.create 10_000 in
  Buffer.add_string buf (preamble grammar);
  E.Pretty.to_buffer buf (format_types grammar);
  Buffer.add_string buf (generate_dumper grammar);
  Buffer.contents buf
