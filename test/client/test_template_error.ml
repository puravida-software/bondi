open Alcotest
module Template_error = Bondi_client.Template_error

let no_newline ~what message =
  check bool
    (Printf.sprintf "%s arrives as one line, got: %s" what
       (String.escaped message))
    false
    (String.contains message '\n')

(* The errors are taken from the library rather than built here: the type is
   the library's, and what this module renders is whatever the library raises
   with. *)
let render_error name =
  match Mustache.render (Mustache.of_string ("{{" ^ name ^ "}}")) (`O []) with
  | rendered ->
      fail
        (Printf.sprintf "expected an unanswered variable to raise, rendered: %s"
           rendered)
  | exception Mustache.Render_error error -> error

let parse_error template =
  match Mustache.of_string template with
  | _ -> fail "expected an unclosed placeholder to raise"
  | exception Mustache.Parse_error error -> error

let short_name = "SHORT"

let long_name =
  "A_VARIABLE_NAME_LONG_ENOUGH_TO_PUSH_THE_SENTENCE_PAST_THE_MARGIN"

(* The reason this module exists rather than [Format.asprintf]: the printer
   writes inside a box, so at the default margin the sentence breaks at a point
   that moves with the length of the variable's name. The second assertion is
   the one that would pass without the margin being touched at all; the third
   is what makes the first two mean something, because a name short enough to
   fit under the default margin proves nothing about a name that is not. *)
let test_a_render_error_is_one_line_whatever_the_name_is_length () =
  no_newline ~what:"a short variable's refusal"
    (Template_error.message ~pp:Mustache.pp_render_error
       (render_error short_name));
  no_newline ~what:"a long variable's refusal"
    (Template_error.message ~pp:Mustache.pp_render_error
       (render_error long_name));
  check bool
    "the default margin does break the long name's sentence, which is why the \
     margin is widened"
    true
    (String.contains
       (Format.asprintf "%a" Mustache.pp_render_error (render_error long_name))
       '\n')

(* The parse error is printed by a different function of the same shape, which
   is the whole reason the printer is an argument. *)
let test_a_parse_error_is_rendered_by_position () =
  let message =
    Template_error.message ~pp:Mustache.pp_template_parse_error
      (parse_error "bondi_server:\n  version: \"{{OOPS\n")
  in
  no_newline ~what:"a malformed template's refusal" message;
  check bool
    (Printf.sprintf "the refusal names the position, got: %s" message)
    true
    (Bondi_common.String_utils.contains ~needle:"Line 3" message)

let () =
  run "Template_error"
    [
      ( "message",
        [
          test_case "a render error is one line whatever the name's length"
            `Quick test_a_render_error_is_one_line_whatever_the_name_is_length;
          test_case "a parse error is rendered by position" `Quick
            test_a_parse_error_is_rendered_by_position;
        ] );
    ]
