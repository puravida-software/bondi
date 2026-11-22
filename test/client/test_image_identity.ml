open Alcotest
open Bondi_client

(* The ids below are read from fixtures/docker_cli/, which holds what a real
   docker CLI printed for each half of [Image_identity.command], byte for byte.
   Its README names the engine and the commands. The command joins the two
   halves with [&&], so a successful answer is the pulled image's capture
   followed by the container's, and that concatenation is what each test feeds
   the verdict. *)
let captured name =
  let path = Filename.concat "fixtures/docker_cli" name in
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let describe = function
  | Image_identity.Same -> "Same"
  | Image_identity.Moved -> "Moved"
  | Image_identity.Unreadable answer ->
      Printf.sprintf "Unreadable %S" (Host_answer.to_string answer)

let check_verdict message ~expected probe =
  check string message (describe expected)
    (describe (Image_identity.verdict probe))

let container_image = captured "inspect_container_image.out"

(* Before the tag moved, the pulled reference names the very image the container
   was created from. *)
let test_equal_ids_are_same () =
  check_verdict "the pulled image is the container's"
    ~expected:Image_identity.Same
    (Ok (captured "image_inspect_id_before_tag_moved.out" ^ container_image))

(* After the tag moved, the container still reports its own image, and the
   pulled reference names the new one. Only the ids show the difference: the
   reference the container was created from reads the same as before. *)
let test_different_ids_are_moved () =
  check_verdict "the tag moved to another image" ~expected:Image_identity.Moved
    (Ok (captured "image_inspect_id_after_tag_moved.out" ^ container_image))

(* Each of these is an answer that does not hold two ids. The last two are the
   affirmative arm: their two lines are equal, so a verdict that compared lines
   without reading them as ids would call them the same image. A template
   prints [<no value>] for a field the object does not have. *)
let test_missing_id_is_unreadable () =
  let unreadable output =
    Image_identity.Unreadable (Host_answer.of_host_output output)
  in
  let pulled = captured "image_inspect_id_before_tag_moved.out" in
  List.iter
    (fun (message, output) ->
      check_verdict message ~expected:(unreadable output) (Ok output))
    [
      ("nothing at all", "");
      ("only the pulled image's id", pulled);
      ("the pulled id and an empty line", pulled ^ "\n");
      ("a third line after both ids", pulled ^ container_image ^ pulled);
      ("two empty lines", "\n\n");
      ("two equal lines that are not ids", "<no value>\n<no value>\n");
    ]

(* The runner's text for a read the host refused, carrying what docker wrote:
   here the pulled reference was not on the box. Quoted as it came, because it
   is the only account of why the ids could not be compared. *)
let test_failed_read_is_unreadable () =
  let failure =
    "command failed (1): " ^ captured "image_inspect_absent_reference.err"
  in
  check_verdict "a failed read is unreadable"
    ~expected:(Image_identity.Unreadable (Host_answer.of_host_output failure))
    (Error failure)

(* The container half, vanished between the listing and this check:
   [docker container inspect] fails, and what it wrote is quoted as it came. *)
let test_vanished_container_is_unreadable () =
  let failure =
    "command failed (1): " ^ captured "inspect_absent_container.err"
  in
  check_verdict "a container that vanished is unreadable"
    ~expected:(Image_identity.Unreadable (Host_answer.of_host_output failure))
    (Error failure);
  check bool "the diagnosis names the missing container" true
    (let needle = "No such container: obs-nothing" in
     let n = String.length needle and h = String.length failure in
     let rec at i =
       i + n <= h && (String.sub failure i n = needle || at (i + 1))
     in
     at 0)

(* The verdict reads the pulled image's id first, so the command must print it
   first. The reference and the name are quoted, so a bracketed registry
   address, which a shell reads as a glob, reaches docker as written. *)
let test_command_reads_pulled_then_running () =
  check string "the pulled image, then the running container"
    "docker image inspect -f '{{.Id}}' \
     'ghcr.io/puravida-software/bondi-orchestrator:0.12.0' && docker container \
     inspect -f '{{.Image}}' 'bondi-orchestrator'"
    (Image_identity.command
       ~image:
         (Test_helpers.image_reference
            "ghcr.io/puravida-software/bondi-orchestrator:0.12.0")
       ~container:"bondi-orchestrator")

let test_command_quotes_a_bracketed_registry () =
  check string "the reference is one word to the shell"
    "docker image inspect -f '{{.Id}}' '[::1]:5000/app:1' && docker container \
     inspect -f '{{.Image}}' 'bondi-orchestrator'"
    (Image_identity.command
       ~image:(Test_helpers.image_reference "[::1]:5000/app:1")
       ~container:"bondi-orchestrator")

let () =
  run "image identity"
    [
      ( "reading both ids after a pull",
        [
          test_case "equal ids are the same image" `Quick
            test_equal_ids_are_same;
          test_case "different ids are a moved tag" `Quick
            test_different_ids_are_moved;
          test_case "a missing id is unreadable" `Quick
            test_missing_id_is_unreadable;
          test_case "a failed read is unreadable" `Quick
            test_failed_read_is_unreadable;
          test_case "the command reads the pulled image, then the container"
            `Quick test_command_reads_pulled_then_running;
          test_case "the command quotes a bracketed registry" `Quick
            test_command_quotes_a_bracketed_registry;
          test_case "a vanished container is unreadable" `Quick
            test_vanished_container_is_unreadable;
        ] );
    ]
