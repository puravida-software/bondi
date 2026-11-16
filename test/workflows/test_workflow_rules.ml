open Alcotest
module Rules = Workflow_rules

let release_file = ".github/workflows/release.yaml"

let rule_name : Rules.rule -> string = function
  | Needs_image_job -> "Needs_image_job"
  | No_bypass -> "No_bypass"
  | Tag_after_gate -> "Tag_after_gate"
  | Latest_after_verify -> "Latest_after_verify"
  | Pinned_action -> "Pinned_action"
  | Run_expression -> "Run_expression"
  | Digested_base -> "Digested_base"
  | Credential_scope -> "Credential_scope"
  | Tap_dry_run -> "Tap_dry_run"
  | Unexpected_shape -> "Unexpected_shape"

let violation =
  testable
    (fun ppf (v : Rules.violation) ->
      Format.fprintf ppf "%s [%s] %s" v.file (rule_name v.rule) v.detail)
    ( = )

let parse text =
  match Yaml.of_string text with
  | Ok doc -> doc
  | Error (`Msg msg) -> failf "fixture does not parse as YAML: %s" msg

(* The three jobs the rule reads, in the shape the shipped workflow gives them.
   [release] and [update-homebrew-tap] publish the client and the formula;
   [release-server] publishes the image. Each fixture below differs from this
   one in the lines it names. *)
let workflow ~release_extra ~server_extra ~tap_extra =
  String.concat "\n"
    ([ "name: release"; "jobs:"; "  release:"; "    runs-on: ubuntu-22.04" ]
    @ release_extra
    @ [
        "    steps:";
        "      - run: echo client";
        "  release-server:";
        "    runs-on: ubuntu-22.04";
      ]
    @ server_extra
    @ [ "  update-homebrew-tap:"; "    runs-on: ubuntu-22.04" ]
    @ tap_extra
    @ [ "    steps:"; "      - run: echo formula"; "" ])

(* The image job's steps in the order the shipped workflow runs them: the floor
   check, both verify steps and the command-surface check, then the push. *)
let server_step name command =
  [ "      - name: " ^ name; "        run: " ^ command ]

let floor_step =
  server_step "Check the tag against the cron version floor"
    "just check-version-floor \"$VERSION\""

let verify_step =
  server_step "Verify the built image runs"
    "just verify-server-image \"$VERSION\""

let verify_negative_step =
  server_step "Verify that the check itself can fail"
    "just verify-server-image-negative \"$VERSION\""

let check_image_step =
  server_step "Check the image's command surface"
    "just check-server-image \"$VERSION\""

let push_step =
  [
    "      - name: Push server image";
    "        run: |";
    "          just push-server \"$VERSION\"";
    "          docker push mlopez1506/bondi-server:latest";
  ]

let server_steps_of steps = "    steps:" :: List.concat steps

let server_steps =
  server_steps_of
    [
      floor_step; verify_step; verify_negative_step; check_image_step; push_step;
    ]

let both_need_image =
  workflow
    ~release_extra:[ "    needs: release-server" ]
    ~server_extra:server_steps
    ~tap_extra:[ "    needs: [release, release-server]" ]

let check_release text = Rules.check_release (parse text)

let needs_image job : Rules.violation =
  {
    file = release_file;
    rule = Needs_image_job;
    detail = Printf.sprintf "job %s does not need release-server" job;
  }

let test_release_without_needs_is_refused () =
  check (list violation) "release, with no needs at all, is reported"
    [ needs_image "release" ]
    (check_release
       (workflow ~release_extra:[] ~server_extra:server_steps
          ~tap_extra:[ "    needs: [release, release-server]" ]))

let test_tap_needing_only_release_is_refused () =
  check (list violation)
    "the formula update, needing the client release alone, is reported"
    [ needs_image "update-homebrew-tap" ]
    (check_release
       (workflow
          ~release_extra:[ "    needs: release-server" ]
          ~server_extra:server_steps ~tap_extra:[ "    needs: release" ]))

let test_needs_as_a_string_is_read () =
  check (list violation) "a string naming release-server satisfies the rule" []
    (check_release
       (workflow
          ~release_extra:[ "    needs: release-server" ]
          ~server_extra:server_steps
          ~tap_extra:[ "    needs: release-server" ]));
  check (list violation) "and a string naming another job does not"
    [ needs_image "release" ]
    (check_release
       (workflow
          ~release_extra:[ "    needs: update-homebrew-tap" ]
          ~server_extra:server_steps
          ~tap_extra:[ "    needs: release-server" ]))

let test_needs_as_a_list_is_read () =
  check (list violation) "a list naming release-server satisfies the rule" []
    (check_release
       (workflow
          ~release_extra:[ "    needs:"; "      - release-server" ]
          ~server_extra:server_steps
          ~tap_extra:
            [ "    needs:"; "      - release"; "      - release-server" ]));
  check (list violation) "and a list naming only other jobs does not"
    [ needs_image "update-homebrew-tap" ]
    (check_release
       (workflow
          ~release_extra:[ "    needs: [release-server]" ]
          ~server_extra:server_steps ~tap_extra:[ "    needs: [release]" ]))

(* The edge that matters is the publishing job's own. A job that does not
   publish needing the image is the edit a reader moving the dependency around
   would plausibly make, and it leaves the formula update unguarded. *)
let test_needs_moved_to_another_job_is_refused () =
  let moved =
    both_need_image
    |> String.split_on_char '\n'
    |> List.map (function
      | "    needs: [release, release-server]" -> "    needs: [release]"
      | line -> line)
    |> String.concat "\n"
  in
  let moved =
    moved
    ^ String.concat "\n"
        [
          "  announce:";
          "    runs-on: ubuntu-22.04";
          "    needs: [release-server]";
          "    steps:";
          "      - run: echo announced";
          "";
        ]
  in
  check (list violation) "the formula update is reported, not the announce job"
    [ needs_image "update-homebrew-tap" ]
    (check_release moved)

let test_both_jobs_needing_release_server_pass () =
  check (list violation) "no violation" [] (check_release both_need_image)

let test_if_always_on_a_dependent_job_is_refused () =
  check (list violation) "an always() condition on the formula update"
    [
      {
        file = release_file;
        rule = No_bypass;
        detail =
          "job update-homebrew-tap: `if: ${{ always() }}` calls a status-check \
           function, so the job can run after a job it needs failed";
      };
    ]
    (check_release
       (workflow
          ~release_extra:[ "    needs: release-server" ]
          ~server_extra:server_steps
          ~tap_extra:
            [
              "    needs: [release, release-server]"; "    if: ${{ always() }}";
            ]));
  check (list violation) "and a status-check function on the client release"
    [
      {
        file = release_file;
        rule = No_bypass;
        detail =
          "job release: `if: !cancelled()` calls a status-check function, so \
           the job can run after a job it needs failed";
      };
    ]
    (check_release
       (workflow
          ~release_extra:
            [ "    needs: release-server"; "    if: '!cancelled()'" ]
          ~server_extra:server_steps
          ~tap_extra:[ "    needs: [release, release-server]" ]));
  check (list violation)
    "a condition calling no status-check function still waits on its needs" []
    (check_release
       (workflow
          ~release_extra:[ "    needs: release-server" ]
          ~server_extra:server_steps
          ~tap_extra:
            [
              "    needs: [release, release-server]";
              "    if: github.repository == 'puravida-software/bondi'";
            ]))

let test_continue_on_error_on_a_server_step_is_refused () =
  let with_verify_line line =
    workflow
      ~release_extra:[ "    needs: release-server" ]
      ~server_extra:
        (server_steps_of
           [
             floor_step;
             [
               "      - name: Verify the built image runs";
               line;
               "        run: just verify-server-image \"$VERSION\"";
             ];
             verify_negative_step;
             check_image_step;
             push_step;
           ])
      ~tap_extra:[ "    needs: [release, release-server]" ]
  in
  check (list violation) "a verify step that may fail without stopping the job"
    [
      {
        file = release_file;
        rule = No_bypass;
        detail =
          "job release-server, step 2 (Verify the built image runs): \
           continue-on-error is set, so a failure there does not stop the \
           steps after it";
      };
    ]
    (check_release (with_verify_line "        continue-on-error: true"));
  check (list violation) "and continue-on-error: false changes nothing" []
    (check_release (with_verify_line "        continue-on-error: false"))

(* A failed step stops the job only for the steps after it whose condition
   carries no status-check function, so a push step that calls one is a way past
   the verification above it. *)
let test_status_check_if_on_a_server_step_is_refused () =
  let with_push_line line =
    workflow
      ~release_extra:[ "    needs: release-server" ]
      ~server_extra:
        (server_steps_of
           [
             floor_step;
             verify_step;
             verify_negative_step;
             check_image_step;
             [
               "      - name: Push server image";
               line;
               "        run: just push-server \"$VERSION\"";
             ];
           ])
      ~tap_extra:[ "    needs: [release, release-server]" ]
  in
  check (list violation) "a push step that runs whatever came before it"
    [
      {
        file = release_file;
        rule = No_bypass;
        detail =
          "job release-server, step 5 (Push server image): `if: Always ()` \
           calls a status-check function, so the step can run after a step \
           before it failed";
      };
    ]
    (check_release (with_push_line "        if: Always ()"));
  check (list violation) "a literal true skips nothing" []
    (check_release (with_push_line "        if: true"))

let test_jobs_not_a_mapping_is_refused () =
  check (list violation) "the reader refuses rather than passes"
    [
      {
        file = release_file;
        rule = Unexpected_shape;
        detail = "jobs is not a mapping of job ids to jobs";
      };
    ]
    (check_release "name: release\njobs:\n  - release\n  - release-server\n")

let test_other_shapes_are_refused () =
  let refused detail : Rules.violation =
    { file = release_file; rule = Unexpected_shape; detail }
  in
  check (list violation) "a publishing job that is absent"
    [ refused "jobs has no job named update-homebrew-tap" ]
    (check_release
       "jobs:\n\
       \  release-server:\n\
       \    steps: []\n\
       \  release:\n\
       \    needs: release-server\n");
  check (list violation) "needs given as a mapping"
    [ refused "job release: needs is neither a job id nor a list of them" ]
    (check_release
       (workflow
          ~release_extra:[ "    needs:"; "      release-server: true" ]
          ~server_extra:server_steps
          ~tap_extra:[ "    needs: [release, release-server]" ]));
  check (list violation) "needs given twice"
    [ refused "job update-homebrew-tap: needs is given more than once" ]
    (check_release
       (workflow
          ~release_extra:[ "    needs: release-server" ]
          ~server_extra:server_steps
          ~tap_extra:[ "    needs: release"; "    needs: release-server" ]));
  check (list violation) "the image job's steps not a list"
    [ refused "job release-server: steps is not a list" ]
    (check_release
       (workflow
          ~release_extra:[ "    needs: release-server" ]
          ~server_extra:[ "    steps: just push-server" ]
          ~tap_extra:[ "    needs: [release, release-server]" ]))

let main_file = ".github/workflows/main.yaml"

(* The main workflow's one job, holding the steps a test names in order. *)
let main_workflow steps =
  String.concat "\n"
    ([
       "name: main";
       "jobs:";
       "  main:";
       "    runs-on: ubuntu-latest";
       "    steps:";
       "      - uses: actions/checkout@v6";
     ]
    @ List.concat steps
    @ [ "" ])

let gate_step = [ "      - name: Run the full gate"; "        run: just" ]

let tag_push_step =
  [
    "      - name: Push the release tag";
    "        run: |";
    "          set -euo pipefail";
    "          git tag \"$RELEASE_TAG\"";
    "          git push origin \"$RELEASE_TAG\"";
  ]

let check_main text = Rules.check_main (parse text)

let ungated_push step : Rules.violation =
  {
    file = main_file;
    rule = Tag_after_gate;
    detail =
      Printf.sprintf
        "job main, step %d (Push the release tag): `git push origin \
         \"$RELEASE_TAG\"` runs with no bare `just` step before it, so the tag \
         can be cut without the full gate having passed"
        step;
  }

let test_tag_push_before_the_gate_is_refused () =
  check (list violation) "the tag pushed, then the gate run"
    [ ungated_push 2 ]
    (check_main (main_workflow [ tag_push_step; gate_step ]))

(* Build and test are two of the gate's recipes. Format, lint and the image
   check are the rest, and only bare `just` runs them all. *)
let test_build_and_test_without_bare_just_is_refused () =
  check (list violation) "just build and just test stand in for the gate"
    [ ungated_push 4 ]
    (check_main
       (main_workflow
          [
            [ "      - name: Build"; "        run: just build" ];
            [ "      - name: Test"; "        run: just test" ];
            tag_push_step;
          ]))

let test_swallowed_gate_failure_is_not_the_gate () =
  check (list violation) "just || true cannot fail, so it gates nothing"
    [ ungated_push 3 ]
    (check_main
       (main_workflow
          [
            [ "      - name: Run the full gate"; "        run: just || true" ];
            tag_push_step;
          ]))

let test_action_gh_release_in_main_is_refused () =
  check (list violation) "the tag and the release created together in main"
    [
      {
        file = main_file;
        rule = Tag_after_gate;
        detail =
          "job main, step 3 (Create GH release): action-gh-release creates the \
           tag and the GitHub release here, before the image for that version \
           exists";
      };
    ]
    (check_main
       (main_workflow
          [
            gate_step;
            [
              "      - name: Create GH release";
              "        uses: softprops/action-gh-release@v1";
              "        with:";
              "          generate_release_notes: true";
            ];
          ]))

let test_bare_just_then_tag_push_passes () =
  check (list violation) "no violation" []
    (check_main (main_workflow [ gate_step; tag_push_step ]))

let test_gate_that_may_fail_is_refused () =
  check (list violation) "a gate step whose failure does not stop the job"
    [
      {
        file = main_file;
        rule = No_bypass;
        detail =
          "job main, step 2 (Run the full gate): continue-on-error is set, so \
           a failure there does not stop the steps after it";
      };
    ]
    (check_main
       (main_workflow
          [ gate_step @ [ "        continue-on-error: true" ]; tag_push_step ]))

let test_no_tag_created_is_refused () =
  check (list violation) "a main workflow that cuts no tag the rule can read"
    [
      {
        file = main_file;
        rule = Unexpected_shape;
        detail =
          "no step pushes a tag with git push or creates one with \
           action-gh-release";
      };
    ]
    (check_main (main_workflow [ gate_step ]))

let pushed_early ~step ~line ~pending : Rules.violation =
  {
    file = release_file;
    rule = Latest_after_verify;
    detail =
      Printf.sprintf
        "job release-server, %s: `%s` runs before these have passed: %s" step
        line pending;
  }

let release_with_server steps =
  check_release
    (workflow
       ~release_extra:[ "    needs: release-server" ]
       ~server_extra:(server_steps_of steps)
       ~tap_extra:[ "    needs: [release, release-server]" ])

let test_push_before_check_server_image_is_refused () =
  check (list violation) "the push moved above the command-surface check"
    [
      pushed_early ~step:"step 4 (Push server image)"
        ~line:"just push-server \"$VERSION\"" ~pending:"just check-server-image";
      pushed_early ~step:"step 4 (Push server image)"
        ~line:"docker push mlopez1506/bondi-server:latest"
        ~pending:"just check-server-image";
    ]
    (release_with_server
       [
         floor_step;
         verify_step;
         verify_negative_step;
         push_step;
         check_image_step;
       ])

let test_latest_pushed_before_verification_is_refused () =
  check (list violation) ":latest pushed in a step of its own, too early"
    [
      pushed_early ~step:"step 2 (Push latest)"
        ~line:"docker push mlopez1506/bondi-server:latest"
        ~pending:
          "just verify-server-image, just verify-server-image-negative, just \
           check-server-image";
    ]
    (release_with_server
       [
         floor_step;
         server_step "Push latest" "docker push mlopez1506/bondi-server:latest";
         verify_step;
         verify_negative_step;
         check_image_step;
         server_step "Push server image" "just push-server \"$VERSION\"";
       ])

let test_absent_verification_is_refused () =
  check (list violation) "a push with the command-surface check gone"
    [
      {
        file = release_file;
        rule = Latest_after_verify;
        detail =
          "job release-server: no step runs just check-server-image, so the \
           push does not wait on it";
      };
    ]
    (release_with_server
       [ floor_step; verify_step; verify_negative_step; push_step ])

let test_push_after_every_verification_passes () =
  check (list violation) "no violation" []
    (release_with_server
       [
         floor_step;
         verify_step;
         verify_negative_step;
         check_image_step;
         push_step;
       ])

let uses_file = ".github/workflows/fixture.yaml"

(* A workflow whose one job runs one step per action reference, in order. *)
let workflow_using references =
  String.concat "\n"
    ([
       "name: fixture";
       "jobs:";
       "  build:";
       "    runs-on: ubuntu-22.04";
       "    steps:";
     ]
    @ List.map (fun reference -> "      - uses: " ^ reference) references
    @ [ "" ])

(* A composite action whose steps run the given action, then a script. *)
let composite_using reference =
  String.concat "\n"
    [
      "name: fixture";
      "description: install dependencies";
      "runs:";
      "  using: composite";
      "  steps:";
      "    - uses: " ^ reference;
      "    - name: Install dependencies";
      "      run: opam install -y --deps-only .";
      "      shell: bash";
      "";
    ]

let check_uses text = Rules.check_uses ~file:uses_file (parse text)

(* Forty lowercase hexadecimal digits, the shape of a full commit SHA. *)
let full_sha = "de0fac2e4500dabe0009e67214ff5f5447ce83dd"

let unpinned ~where reference : Rules.violation =
  {
    file = uses_file;
    rule = Pinned_action;
    detail =
      Printf.sprintf "%s: `%s` is not pinned to a full-length commit SHA" where
        reference;
  }

let test_tag_ref_is_refused () =
  check (list violation) "an action referenced by a tag is reported"
    [ unpinned ~where:"job build, step 1" "softprops/action-gh-release@v1" ]
    (check_uses (workflow_using [ "softprops/action-gh-release@v1" ]))

let test_short_sha_is_refused () =
  let short = String.sub full_sha 0 39 in
  check (list violation) "a SHA one digit short is reported"
    [ unpinned ~where:"job build, step 1" ("actions/checkout@" ^ short) ]
    (check_uses (workflow_using [ "actions/checkout@" ^ short ]))

let test_full_sha_passes () =
  check (list violation) "an action referenced by a full SHA is not reported" []
    (check_uses (workflow_using [ "softprops/action-gh-release@" ^ full_sha ]))

let test_sub_path_full_sha_passes () =
  check (list violation) "an action in a sub-path, at a full SHA, passes" []
    (check_uses (workflow_using [ "ocaml/setup-ocaml/lint-fmt@" ^ full_sha ]));
  check (list violation) "and the same sub-path at a tag is reported"
    [ unpinned ~where:"job build, step 1" "ocaml/setup-ocaml/lint-fmt@v3" ]
    (check_uses (workflow_using [ "ocaml/setup-ocaml/lint-fmt@v3" ]))

let test_local_ref_is_exempt () =
  check (list violation)
    "a local action is not reported, and the step after it is still read"
    [ unpinned ~where:"job build, step 2" "extractions/setup-just@v3" ]
    (check_uses
       (workflow_using
          [ "./.github/actions/ocaml-deps"; "extractions/setup-just@v3" ]))

let test_composite_steps_are_scanned () =
  check (list violation) "a tag in a composite action's steps is reported"
    [ unpinned ~where:"runs, step 1" "ocaml/setup-ocaml@v3" ]
    (check_uses (composite_using "ocaml/setup-ocaml@v3"));
  check (list violation) "and a full SHA there is not" []
    (check_uses (composite_using ("ocaml/setup-ocaml@" ^ full_sha)))

(* A workflow whose one step runs [script], optionally binding [env] first. *)
let workflow_running ?(env = []) script =
  String.concat "\n"
    ([
       "name: fixture";
       "jobs:";
       "  build:";
       "    runs-on: ubuntu-22.04";
       "    steps:";
       "      - name: Package";
     ]
    @ (if env = [] then []
       else "        env:" :: List.map (fun line -> "          " ^ line) env)
    @ [ "        run: " ^ script; "" ])

let interpolated ~where : Rules.violation =
  {
    file = uses_file;
    rule = Run_expression;
    detail =
      Printf.sprintf
        "%s: the run script holds a `${{` expression, which is substituted \
         into the script text before the shell reads it; bind it under env and \
         read the variable"
        where;
  }

let test_run_expression_is_refused () =
  check (list violation) "an expression inside a run script is reported"
    [ interpolated ~where:"job build, step 1 (Package)" ]
    (check_uses
       (workflow_running {|"tar -czf bondi-${{ matrix.platform }}.tar.gz"|}));
  check (list violation) "an expression with no spaces inside is reported too"
    [ interpolated ~where:"job build, step 1 (Package)" ]
    (check_uses (workflow_running {|"echo ${{github.sha}}"|}));
  check (list violation) "an expression bound under env and read as a variable"
    []
    (check_uses
       (workflow_running
          ~env:[ "PLATFORM: ${{ matrix.platform }}" ]
          {|"tar -czf bondi-${PLATFORM}.tar.gz"|}))

let test_uses_shapes_are_refused () =
  let refused detail : Rules.violation =
    { file = uses_file; rule = Unexpected_shape; detail }
  in
  check (list violation) "a document that is neither a workflow nor an action"
    [
      refused
        "the document has neither jobs (a workflow) nor runs (a composite \
         action)";
    ]
    (check_uses "name: fixture\non: push\n");
  check (list violation) "an action reference that is not a string"
    [ refused "job build, step 1: uses is not an action reference" ]
    (check_uses (workflow_using [ "[actions/checkout, v6]" ]));
  check (list violation) "a composite action with no steps"
    [ refused "runs has no steps" ]
    (check_uses "name: fixture\nruns:\n  using: node20\n  main: index.js\n")

let dockerfile = "Dockerfile"
let check_dockerfile lines = Rules.check_dockerfile (String.concat "\n" lines)

(* Sixty-four lowercase hexadecimal digits, the shape of a sha256 digest. *)
let sha256 = "sha256:" ^ String.concat "" (List.init 8 (fun _ -> "0f1e2d3c"))

let undigested ~line image : Rules.violation =
  {
    file = dockerfile;
    rule = Digested_base;
    detail =
      Printf.sprintf "line %d: `%s` is not pinned to a sha256 content digest"
        line image;
  }

let test_tag_only_from_is_refused () =
  check (list violation) "a base image named by its tag alone is reported"
    [ undigested ~line:2 "alpine:3.24.4" ]
    (check_dockerfile [ "# Runtime stage"; "FROM alpine:3.24.4"; "USER app" ]);
  check (list violation)
    "and so is one written with a lowercase instruction and a platform flag"
    [ undigested ~line:1 "alpine:3.24.4" ]
    (check_dockerfile [ "from --platform=linux/amd64 alpine:3.24.4" ]);
  check (list violation) "a digest in a comment above it does not pin it"
    [ undigested ~line:2 "alpine:3.24.4" ]
    (check_dockerfile
       [ "# FROM alpine:3.24.4@" ^ sha256; "FROM alpine:3.24.4" ])

let test_tag_plus_digest_passes () =
  check (list violation) "a base image carrying a sha256 digest is not reported"
    []
    (check_dockerfile [ "# Runtime stage"; "FROM alpine:3.24.4@" ^ sha256 ]);
  let short = String.sub sha256 0 (String.length sha256 - 1) in
  check (list violation) "and the same image one digit short is reported"
    [ undigested ~line:2 ("alpine:3.24.4@" ^ short) ]
    (check_dockerfile [ "# Runtime stage"; "FROM alpine:3.24.4@" ^ short ])

let test_earlier_stage_name_is_exempt () =
  let builder = "ocaml/opam:alpine-ocaml-5.5@" ^ sha256 in
  check (list violation)
    "a FROM naming a stage declared above is not reported, and the external \
     FROM after it is still read"
    [ undigested ~line:4 "alpine:3.24.4" ]
    (check_dockerfile
       [
         "FROM " ^ builder ^ " AS builder";
         "RUN make";
         "FROM builder";
         "FROM alpine:3.24.4";
       ]);
  check (list violation)
    "a FROM naming a stage that is only declared below it is an image, and is \
     reported"
    [ undigested ~line:1 "builder" ]
    (check_dockerfile [ "FROM builder"; "FROM " ^ builder ^ " AS builder" ])

let test_dockerfile_shapes_are_refused () =
  let refused detail : Rules.violation =
    { file = dockerfile; rule = Unexpected_shape; detail }
  in
  check (list violation) "a file with no FROM instruction"
    [ refused "the file has no FROM instruction, so it names no base image" ]
    (check_dockerfile [ "# a comment"; "RUN make" ]);
  check (list violation) "a FROM that is not an image and an optional AS name"
    [ refused "line 1: FROM is not `FROM [--flag ...] <image> [AS <name>]`" ]
    (check_dockerfile [ "FROM alpine:3.24.4@" ^ sha256 ^ " builder" ])

(* Resolved from the executable rather than the working directory, so the path
   is the same under [dune runtest] and [dune exec]. *)
let shipped_path file =
  List.fold_left Filename.concat
    (Filename.dirname Sys.executable_name)
    [ Filename.parent_dir_name; Filename.parent_dir_name; file ]

let shipped file =
  In_channel.with_open_bin (shipped_path file) In_channel.input_all

let is_yaml name =
  String.ends_with ~suffix:".yaml" name || String.ends_with ~suffix:".yml" name

let sorted_entries dir =
  List.sort String.compare (Array.to_list (Sys.readdir (shipped_path dir)))

(* Every file under [dir] named [action.yaml] or [action.yml], at any depth:
   the domain of the dune glob that copies them into the build tree. *)
let rec action_files dir =
  List.concat_map
    (fun name ->
      let path = Filename.concat dir name in
      if Sys.is_directory (shipped_path path) then action_files path
      else if name = "action.yaml" || name = "action.yml" then [ path ]
      else [])
    (sorted_entries dir)

(* Every workflow and every composite action in the build tree, listed rather
   than named, so a file added later is checked without editing this list. *)
let shipped_actions_and_workflows () =
  let workflows_dir = ".github/workflows" in
  let workflows =
    List.filter_map
      (fun name ->
        if is_yaml name then Some (Filename.concat workflows_dir name) else None)
      (sorted_entries workflows_dir)
  in
  workflows @ action_files ".github/actions"

let test_real_release_yaml_passes () =
  check (list violation) "the shipped release workflow breaks no rule" []
    (check_release (shipped release_file))

let test_real_main_yaml_passes () =
  check (list violation) "the shipped main workflow breaks no rule" []
    (check_main (shipped main_file))

let test_real_dockerfile_passes () =
  check (list violation)
    "every base image the shipped Dockerfile builds on carries a digest" []
    (Rules.check_dockerfile (shipped dockerfile))

let test_real_actions_are_pinned () =
  let files = shipped_actions_and_workflows () in
  (* An empty listing would pass the check below while reading nothing, so the
     listing must reach both shapes: a workflow and a composite action. These
     are named here, apart from the directory read that found them. *)
  List.iter
    (fun file ->
      check bool
        (file ^ " is among the files checked")
        true (List.mem file files))
    [ release_file; main_file; ".github/actions/ocaml-deps/action.yaml" ];
  check (list violation)
    "every action any workflow or composite action references is pinned to a \
     commit SHA"
    []
    (List.concat_map
       (fun file -> Rules.check_uses ~file (parse (shipped file)))
       files)

(* Every string under a [uses] key, at any depth. *)
let rec uses_values (doc : Yaml.value) =
  match doc with
  | `O pairs ->
      List.concat_map
        (fun (key, value) ->
          match (key, value) with
          | "uses", `String action -> [ action ]
          | _ -> uses_values value)
        pairs
  | `A items -> List.concat_map uses_values items
  | `Null
  | `Bool _
  | `Float _
  | `String _ ->
      []

(* A local reference may be written from a checkout's own directory, as
   [./main/.github/actions/x]; the action is the part from [.github/] on. *)
let local_action_dir reference =
  let marker = ".github/" in
  let rec from i =
    if i + String.length marker > String.length reference then None
    else if String.sub reference i (String.length marker) = marker then
      Some (String.sub reference i (String.length reference - i))
    else from (i + 1)
  in
  from 0

(* Pinned_action exempts a local reference without reading it, so a misspelt
   path would pass the rule and fail only when the job runs. *)
let test_real_local_actions_exist () =
  let files = shipped_actions_and_workflows () in
  let referenced =
    List.concat_map
      (fun file ->
        List.filter_map
          (fun action ->
            if String.starts_with ~prefix:"./" action then Some (file, action)
            else None)
          (uses_values (parse (shipped file))))
      files
  in
  check bool "the shipped files reference at least one local action" true
    (referenced <> []);
  List.iter
    (fun (file, action) ->
      match local_action_dir action with
      | None -> failf "%s: local `%s` is not under .github/" file action
      | Some dir ->
          check bool
            (Printf.sprintf "%s: local `%s` has an action file" file action)
            true
            (List.exists
               (fun name -> List.mem (Filename.concat dir name) files)
               [ "action.yaml"; "action.yml" ]))
    referenced

(* The tag pushed from main starts this workflow; the release is created here,
   after the image. *)
let test_real_release_created_after_the_image () =
  check (list violation)
    "the shipped release workflow creates the release only in a job needing \
     release-server"
    []
    (Rules.check_release_creation (parse (shipped release_file)))

let dry_run_file = ".github/workflows/release-dry-run.yaml"

(* The packaging copy is this repository's own formula, so a dry run over it
   alone passes while the tap's formula, laid out differently, is refused at
   release time. The tap is public: the default token reads it, and no write
   credential reaches a pull request. *)
let test_real_dry_run_updates_a_tap_checkout () =
  check (list violation)
    "the shipped dry run updates a formula inside a tap checkout, read-only" []
    (Rules.check_dry_run_tap (parse (shipped dry_run_file)))

(* A release workflow of the jobs a test names, each with its [needs] and one
   step. *)
let release_creation_workflow jobs =
  String.concat "\n"
    ([ "name: release"; "jobs:" ]
    @ List.concat_map
        (fun (job, needs, uses) ->
          [ "  " ^ job ^ ":"; "    runs-on: ubuntu-latest" ]
          @ (match needs with
            | Some needs -> [ "    needs: " ^ needs ]
            | None -> [])
          @ [ "    steps:"; "      - uses: " ^ uses ])
        jobs
    @ [ "" ])

let creates = "softprops/action-gh-release@v2"

let unordered_release job : Rules.violation =
  {
    file = release_file;
    rule = Needs_image_job;
    detail =
      Printf.sprintf
        "job %s creates the GitHub release but does not need release-server, \
         so a release can exist for a version whose image did not publish"
        job;
  }

let check_release_creation text = Rules.check_release_creation (parse text)

let test_release_created_without_the_image_is_refused () =
  check (list violation) "a release created in a job with no needs is reported"
    [ unordered_release "release" ]
    (check_release_creation
       (release_creation_workflow
          [
            ("release-server", None, "actions/checkout@v6");
            ("release", None, creates);
          ]));
  check (list violation) "and so is one in a job needing another job only"
    [ unordered_release "release" ]
    (check_release_creation
       (release_creation_workflow
          [
            ("release-server", None, "actions/checkout@v6");
            ("release", Some "build", creates);
          ]));
  check (list violation) "the action name is read in any case"
    [ unordered_release "release" ]
    (check_release_creation
       (release_creation_workflow
          [ ("release", None, "SoftProps/Action-GH-Release@v2") ]));
  check (list violation) "a job needing release-server passes" []
    (check_release_creation
       (release_creation_workflow
          [
            ("release-server", None, "actions/checkout@v6");
            ("release", Some "release-server", creates);
          ]))

let test_release_creation_shapes_are_refused () =
  let refused detail : Rules.violation =
    { file = release_file; rule = Unexpected_shape; detail }
  in
  check (list violation) "a workflow in which nothing creates the release"
    [ refused "no step creates the GitHub release with action-gh-release" ]
    (check_release_creation
       (release_creation_workflow
          [ ("release-server", None, "actions/checkout@v6") ]));
  check (list violation) "a job whose steps are not a list"
    [
      refused "job release: steps is not a list";
      refused "no step creates the GitHub release with action-gh-release";
    ]
    (check_release_creation
       (String.concat "\n"
          [ "jobs:"; "  release:"; "    steps: not-a-list"; "" ]))

let tap_checkout ?(extra = [])
    ?(repository = "puravida-software/homebrew-bondi")
    ?(path = Some "homebrew-tap") () =
  [ "      - uses: actions/checkout@v6"; "        with:" ]
  @ [ "          repository: " ^ repository ]
  @ (match path with
    | Some path -> [ "          path: " ^ path ]
    | None -> [])
  @ extra

let tap_update ?(formula = "homebrew-tap/Formula/bondi.rb") () =
  [
    "      - uses: ./.github/actions/update-homebrew-formula";
    "        with:";
    "          formula-path: " ^ formula;
  ]

let dry_run_workflow steps =
  String.concat "\n"
    ([
       "name: release-dry-run";
       "jobs:";
       "  update-homebrew-tap-dry-run:";
       "    runs-on: ubuntu-latest";
       "    steps:";
     ]
    @ List.concat steps
    @ [ "" ])

let check_dry_run_tap steps =
  Rules.check_dry_run_tap (parse (dry_run_workflow steps))

let tap_violation detail : Rules.violation =
  { file = dry_run_file; rule = Tap_dry_run; detail }

let tap_shape detail : Rules.violation =
  { file = dry_run_file; rule = Unexpected_shape; detail }

let test_dry_run_tap_refusals () =
  check (list violation) "a tap checked out before the updater edits it passes"
    []
    (check_dry_run_tap [ tap_checkout (); tap_update () ]);
  check (list violation) "the repository name is read in any case" []
    (check_dry_run_tap
       [
         tap_checkout ~repository:"Puravida-Software/Homebrew-Bondi" ();
         tap_update ();
       ]);
  check (list violation) "an updater that edits only a copy is reported"
    [
      tap_violation
        "job update-homebrew-tap-dry-run runs no formula update on a formula \
         inside a tap checkout made before it, so the dry run does not read \
         the tap's own layout";
    ]
    (check_dry_run_tap
       [ tap_checkout (); tap_update ~formula:"tmp/tap/Formula/bondi.rb" () ]);
  check (list violation) "an updater that runs before the checkout is reported"
    [
      tap_violation
        "job update-homebrew-tap-dry-run runs no formula update on a formula \
         inside a tap checkout made before it, so the dry run does not read \
         the tap's own layout";
    ]
    (check_dry_run_tap [ tap_update (); tap_checkout () ]);
  check (list violation) "a job that never checks out the tap is reported"
    [ tap_violation "job update-homebrew-tap-dry-run never checks out the tap" ]
    (check_dry_run_tap [ tap_update ~formula:"x/Formula/bondi.rb" () ]);
  check (list violation) "a token given to the tap checkout is reported"
    [
      tap_violation
        "job update-homebrew-tap-dry-run, step 1: the checkout of the tap is \
         given a token, so the dry run is not read-only";
    ]
    (check_dry_run_tap
       [
         tap_checkout ~extra:[ "          token: ${{ secrets.PAT_GITHUB }}" ] ();
         tap_update ();
       ]);
  check (list violation) "a tap checkout with no path is refused"
    [
      tap_shape
        "job update-homebrew-tap-dry-run, step 1: the checkout of the tap has \
         no path, so it would replace the workspace";
      tap_violation
        "job update-homebrew-tap-dry-run runs no formula update on a formula \
         inside a tap checkout made before it, so the dry run does not read \
         the tap's own layout";
    ]
    (check_dry_run_tap [ tap_checkout ~path:None (); tap_update () ]);
  check (list violation) "an updater with no formula-path is refused"
    [
      tap_shape
        "job update-homebrew-tap-dry-run, step 2: the updater has no \
         formula-path";
      tap_violation
        "job update-homebrew-tap-dry-run runs no formula update on a formula \
         inside a tap checkout made before it, so the dry run does not read \
         the tap's own layout";
    ]
    (check_dry_run_tap
       [
         tap_checkout ();
         [
           "      - uses: ./.github/actions/update-homebrew-formula";
           "        with:";
           "          dry-run: \"true\"";
         ];
       ]);
  check (list violation) "a workflow without the job is refused"
    [ tap_shape "jobs has no job named update-homebrew-tap-dry-run" ]
    (Rules.check_dry_run_tap (parse "jobs:\n  other:\n    steps: []\n"))

let skippable ~step ~name : Rules.violation =
  {
    file = release_file;
    rule = No_bypass;
    detail =
      Printf.sprintf
        "job release-server, step %d (%s): this step carries an `if` other \
         than a literal true, so it can be skipped"
        step name;
  }

let release_with_verify_lines lines =
  workflow
    ~release_extra:[ "    needs: release-server" ]
    ~server_extra:
      (server_steps_of
         [
           floor_step;
           [ "      - name: Verify the built image runs" ]
           @ lines
           @ [ "        run: just verify-server-image \"$VERSION\"" ];
           verify_negative_step;
           check_image_step;
           push_step;
         ])
    ~tap_extra:[ "    needs: [release, release-server]" ]

let main_with_gate_lines lines =
  main_workflow
    [
      [ "      - name: Run the full gate" ] @ lines @ [ "        run: just" ];
      tag_push_step;
    ]

let test_skippable_verify_step_is_refused () =
  let verify = skippable ~step:2 ~name:"Verify the built image runs" in
  check (list violation) "if: false on a verify step" [ verify ]
    (check_release (release_with_verify_lines [ "        if: false" ]));
  check (list violation) "a non-status expression on a verify step" [ verify ]
    (check_release
       (release_with_verify_lines [ "        if: github.ref_type == 'tag'" ]));
  check (list violation) "a literal true on a verify step" []
    (check_release (release_with_verify_lines [ "        if: 'true'" ]))

let test_skippable_gate_step_is_refused () =
  let gate =
    {
      Rules.file = main_file;
      rule = No_bypass;
      detail =
        "job main, step 2 (Run the full gate): this step carries an `if` other \
         than a literal true, so it can be skipped";
    }
  in
  check (list violation) "if: false on the gate step" [ gate ]
    (check_main (main_with_gate_lines [ "        if: false" ]));
  check (list violation) "a non-status expression on the gate step" [ gate ]
    (check_main
       (main_with_gate_lines [ "        if: github.ref_type == 'tag'" ]))

let test_shell_on_a_verified_step_is_refused () =
  check (list violation) "a step-level shell on a verify step"
    [
      {
        file = release_file;
        rule = No_bypass;
        detail =
          "job release-server, step 2 (Verify the built image runs): shell is \
           set, so the step may not stop at the first failure";
      };
    ]
    (check_release (release_with_verify_lines [ "        shell: bash {0}" ]))

let test_set_plus_e_in_a_verified_step_is_refused () =
  check (list violation) "set +e ahead of the verify line"
    [
      {
        file = release_file;
        rule = No_bypass;
        detail =
          "job release-server, step 2 (Verify the built image runs): `set +e` \
           turns off exit on failure for the lines after it";
      };
    ]
    (check_release
       (workflow
          ~release_extra:[ "    needs: release-server" ]
          ~server_extra:
            (server_steps_of
               [
                 floor_step;
                 [
                   "      - name: Verify the built image runs";
                   "        run: |";
                   "          set +e";
                   "          just verify-server-image \"$VERSION\"";
                 ];
                 verify_negative_step;
                 check_image_step;
                 push_step;
               ])
          ~tap_extra:[ "    needs: [release, release-server]" ]))

let test_status_function_split_across_lines_is_refused () =
  check (list violation) "always followed by a newline before the bracket"
    [
      {
        file = release_file;
        rule = No_bypass;
        detail =
          "job release-server, step 5 (Push server image): `if: always\n\
           ()\n\
           ` calls a status-check function, so the step can run after a step \
           before it failed";
      };
    ]
    (check_release
       (workflow
          ~release_extra:[ "    needs: release-server" ]
          ~server_extra:
            (server_steps_of
               [
                 floor_step;
                 verify_step;
                 verify_negative_step;
                 check_image_step;
                 [
                   "      - name: Push server image";
                   "        if: |";
                   "          always";
                   "          ()";
                   "        run: just push-server \"$VERSION\"";
                 ];
               ])
          ~tap_extra:[ "    needs: [release, release-server]" ]))

let early_push command =
  release_with_server
    [
      [ "      - name: Push early"; "        run: " ^ command ];
      floor_step;
      verify_step;
      verify_negative_step;
      check_image_step;
    ]

let test_other_image_push_forms_are_held_to_the_order () =
  let violations found =
    List.map (fun (v : Rules.violation) -> rule_name v.rule) found
  in
  List.iter
    (fun command ->
      check (list string)
        ("an early push by " ^ command)
        [ "Latest_after_verify" ]
        (violations (early_push command)))
    [
      "docker buildx build --push -t x .";
      "docker image push x";
      "docker buildx imagetools create -t x:latest x:1";
    ];
  check (list string) "an early push by build-push-action"
    [ "Latest_after_verify" ]
    (violations
       (release_with_server
          [
            [
              "      - uses: docker/build-push-action@abc";
              "        with:";
              "          push: true";
            ];
            floor_step;
            verify_step;
            verify_negative_step;
            check_image_step;
          ]))

let test_other_tag_push_forms_are_held_to_the_gate () =
  List.iter
    (fun command ->
      check (list string)
        ("an ungated tag by " ^ command)
        [ "Tag_after_gate" ]
        (List.map
           (fun (v : Rules.violation) -> rule_name v.rule)
           (check_main
              (main_workflow
                 [
                   [ "      - name: Cut"; "        run: " ^ command ]; gate_step;
                 ]))))
    [ "gh release create v1"; "gh api repos/o/r/git/refs -f ref=refs/tags/v1" ]

let checkout_with lines =
  [ "      - uses: actions/checkout@v6"; "        with:" ] @ lines

let token_on_checkout step : Rules.violation =
  {
    file = main_file;
    rule = Credential_scope;
    detail =
      Printf.sprintf
        "job main, step %d: the checkout is given a token, which persists in \
         the repository's git config for every later step of the job"
        step;
  }

(* The checkout persists whatever token it is given for every later step, so
   the gate would run with the write credential in its git config. *)
let test_token_on_a_checkout_is_refused () =
  check (list violation) "a token given to a checkout is reported"
    [ token_on_checkout 2 ]
    (check_main
       (main_workflow
          [
            checkout_with [ "          token: ${{ secrets.PAT_GITHUB }}" ];
            gate_step;
            tag_push_step;
          ]));
  check (list violation) "and so is one given an unrelated token value"
    [ token_on_checkout 2 ]
    (check_main
       (main_workflow
          [
            checkout_with [ "          token: x"; "          fetch-depth: 0" ];
            gate_step;
            tag_push_step;
          ]));
  check (list violation) "a checkout with no token, persisting none, passes" []
    (check_main
       (main_workflow
          [
            checkout_with [ "          persist-credentials: false" ];
            gate_step;
            tag_push_step;
          ]));
  check (list violation)
    "and so does the credential bound under env in the push" []
    (check_main
       (main_workflow
          [
            gate_step;
            [
              "      - name: Push the release tag";
              "        env:";
              "          PAT: ${{ secrets.PAT_GITHUB }}";
              "        run: |";
              "          git push \
               \"https://x-access-token:${PAT}@github.com/${GITHUB_REPOSITORY}\" \
               \"$RELEASE_TAG\"";
            ];
          ]))

let test_scratch_from_is_exempt_and_arg_base_is_refused () =
  check (list violation) "FROM scratch needs no digest, in any case" []
    (check_dockerfile [ "FROM scratch"; "from SCRATCH AS final"; "COPY a /a" ]);
  check (list violation) "a FROM of a build argument is refused on purpose"
    [ undigested ~line:2 "$BASE" ]
    (check_dockerfile [ "ARG BASE=alpine:3.24.4@" ^ sha256; "FROM $BASE" ]);
  check (list violation) "an image merely starting with scratch is refused"
    [ undigested ~line:1 "scratchy:1" ]
    (check_dockerfile [ "FROM scratchy:1" ])

let () =
  run "Workflow rules"
    [
      ( "needs_image_job",
        [
          test_case "release without needs is refused" `Quick
            test_release_without_needs_is_refused;
          test_case "tap needing only release is refused" `Quick
            test_tap_needing_only_release_is_refused;
          test_case "needs as a string is read" `Quick
            test_needs_as_a_string_is_read;
          test_case "needs as a list is read" `Quick
            test_needs_as_a_list_is_read;
          test_case "needs moved to another job is refused" `Quick
            test_needs_moved_to_another_job_is_refused;
          test_case "both jobs needing release-server pass" `Quick
            test_both_jobs_needing_release_server_pass;
        ] );
      ( "no_bypass",
        [
          test_case "if always() on a dependent job is refused" `Quick
            test_if_always_on_a_dependent_job_is_refused;
          test_case "continue-on-error on a release-server step is refused"
            `Quick test_continue_on_error_on_a_server_step_is_refused;
          test_case "a status-check if on a release-server step is refused"
            `Quick test_status_check_if_on_a_server_step_is_refused;
        ] );
      ( "tag_after_gate",
        [
          test_case "tag push before the just step is refused" `Quick
            test_tag_push_before_the_gate_is_refused;
          test_case "just build and just test without bare just is refused"
            `Quick test_build_and_test_without_bare_just_is_refused;
          test_case "just with its failure swallowed is not the gate" `Quick
            test_swallowed_gate_failure_is_not_the_gate;
          test_case "action-gh-release creating the tag in main is refused"
            `Quick test_action_gh_release_in_main_is_refused;
          test_case "a gate step that may fail is refused" `Quick
            test_gate_that_may_fail_is_refused;
          test_case "no tag created is refused" `Quick
            test_no_tag_created_is_refused;
          test_case "bare just then the tag push passes" `Quick
            test_bare_just_then_tag_push_passes;
        ] );
      ( "latest_after_verify",
        [
          test_case "push before check-server-image is refused" `Quick
            test_push_before_check_server_image_is_refused;
          test_case
            "latest pushed in an earlier step than verification is refused"
            `Quick test_latest_pushed_before_verification_is_refused;
          test_case "an absent verification step is refused" `Quick
            test_absent_verification_is_refused;
          test_case "push after floor, verify and check steps passes" `Quick
            test_push_after_every_verification_passes;
        ] );
      ( "pinned_action",
        [
          test_case "tag ref @v1 is refused" `Quick test_tag_ref_is_refused;
          test_case "39-hex ref is refused" `Quick test_short_sha_is_refused;
          test_case "40-hex ref passes" `Quick test_full_sha_passes;
          test_case "sub-path action with 40-hex ref passes" `Quick
            test_sub_path_full_sha_passes;
          test_case "local ./ ref is exempt" `Quick test_local_ref_is_exempt;
          test_case "an expression inside a run script is refused" `Quick
            test_run_expression_is_refused;
          test_case "composite action steps are scanned" `Quick
            test_composite_steps_are_scanned;
        ] );
      ( "digested_base",
        [
          test_case "tag-only FROM is refused" `Quick
            test_tag_only_from_is_refused;
          test_case "tag plus @sha256 digest passes" `Quick
            test_tag_plus_digest_passes;
          test_case "FROM of an earlier stage name is exempt" `Quick
            test_earlier_stage_name_is_exempt;
          test_case "FROM scratch is exempt and an ARG base is refused" `Quick
            test_scratch_from_is_exempt_and_arg_base_is_refused;
        ] );
      ( "no_bypass_strict",
        [
          test_case "if other than true on a verify step is refused" `Quick
            test_skippable_verify_step_is_refused;
          test_case "if other than true on the gate step is refused" `Quick
            test_skippable_gate_step_is_refused;
          test_case "shell on a verified step is refused" `Quick
            test_shell_on_a_verified_step_is_refused;
          test_case "set +e in a verified step is refused" `Quick
            test_set_plus_e_in_a_verified_step_is_refused;
          test_case "status function split across lines is refused" `Quick
            test_status_function_split_across_lines_is_refused;
          test_case "other image push forms are held to the order" `Quick
            test_other_image_push_forms_are_held_to_the_order;
          test_case "other tag push forms are held to the gate" `Quick
            test_other_tag_push_forms_are_held_to_the_gate;
          test_case "a token on a checkout is refused" `Quick
            test_token_on_a_checkout_is_refused;
          test_case "a release created without the image is refused" `Quick
            test_release_created_without_the_image_is_refused;
          test_case "a dry run that does not read the tap is refused" `Quick
            test_dry_run_tap_refusals;
        ] );
      ( "unexpected_shape",
        [
          test_case "jobs not a mapping is refused" `Quick
            test_jobs_not_a_mapping_is_refused;
          test_case "other shapes the rule does not read are refused" `Quick
            test_other_shapes_are_refused;
          test_case "shapes the pinned-action rule does not read are refused"
            `Quick test_uses_shapes_are_refused;
          test_case "shapes the base-image rule does not read are refused"
            `Quick test_dockerfile_shapes_are_refused;
          test_case "shapes the release-creation rule does not read are refused"
            `Quick test_release_creation_shapes_are_refused;
        ] );
      ( "real tree",
        [
          test_case "release.yaml passes check_release" `Quick
            test_real_release_yaml_passes;
          test_case "main.yaml passes check_main" `Quick
            test_real_main_yaml_passes;
          test_case "every workflow and composite action passes check_uses"
            `Quick test_real_actions_are_pinned;
          test_case "every shipped local ref names an action file" `Quick
            test_real_local_actions_exist;
          test_case "Dockerfile passes check_dockerfile" `Quick
            test_real_dockerfile_passes;
          test_case
            "release.yaml creates the GitHub release in a job needing \
             release-server"
            `Quick test_real_release_created_after_the_image;
          test_case "release-dry-run updates a checkout of the tap" `Quick
            test_real_dry_run_updates_a_tap_checkout;
        ] );
    ]
