type rule =
  | Needs_image_job
  | No_bypass
  | Tag_after_gate
  | Latest_after_verify
  | Pinned_action
  | Run_expression
  | Digested_base
  | Credential_scope
  | Tap_dry_run
  | Unexpected_shape

type violation = { file : string; rule : rule; detail : string }

let release_file = ".github/workflows/release.yaml"
let main_file = ".github/workflows/main.yaml"
let dry_run_file = ".github/workflows/release-dry-run.yaml"

(* The client release and the formula update each wait on the image job itself,
   not only through one another: a condition on the job in between would
   otherwise be enough to let the later one through. *)
let image_job = "release-server"
let at ~file rule detail = { file; rule; detail }
let shape ~file detail = at ~file Unexpected_shape detail
let at_release rule detail = at ~file:release_file rule detail

(* A key given twice is a document whose meaning depends on which reader is
   asked, so it is refused rather than read as either occurrence. *)
let field ~file ~where key pairs =
  match List.filter (fun (k, _) -> String.equal k key) pairs with
  | [] -> Ok None
  | [ (_, value) ] -> Ok (Some value)
  | _ :: _ :: _ ->
      Error
        (shape ~file
           (Printf.sprintf "%s: %s is given more than once" where key))

(* GitHub adds an implicit [success()] to a condition only when the condition
   calls none of the status-check functions itself. With one, the expression
   alone decides whether the job or step runs after a failure. Function names in
   expressions are case-insensitive and may be followed by whitespace. All of
   this is assumed from documentation, none of it observed on a runner:
   https://docs.github.com/en/actions/reference/workflows-and-actions/expressions
   covers the implicit [success()]; the name case and whitespace points are not
   stated there, so they are held as a precaution. *)
let calls_status_function expression =
  let normalised =
    String.lowercase_ascii expression
    |> String.to_seq
    |> Seq.filter (fun c ->
        not
          (Char.equal c ' '
          || Char.equal c '\t'
          || Char.equal c '\n'
          || Char.equal c '\r'))
    |> String.of_seq
  in
  List.exists
    (fun name -> Test_helpers.contains ~needle:(name ^ "(") normalised)
    [ "success"; "failure"; "always"; "cancelled" ]

let job_named ~file jobs name =
  match field ~file ~where:"jobs" name jobs with
  | Error v -> Error v
  | Ok None ->
      Error (shape ~file (Printf.sprintf "jobs has no job named %s" name))
  | Ok (Some (`O pairs)) -> Ok pairs
  | Ok (Some (`Null | `Bool _ | `Float _ | `String _ | `A _)) ->
      Error (shape ~file (Printf.sprintf "job %s is not a mapping" name))

let needed_job_ids ~job pairs =
  let file = release_file in
  let not_an_id () =
    Error
      (shape ~file
         (Printf.sprintf "job %s: needs is neither a job id nor a list of them"
            job))
  in
  match field ~file ~where:("job " ^ job) "needs" pairs with
  | Error v -> Error v
  | Ok None -> Ok []
  | Ok (Some (`String id)) -> Ok [ id ]
  | Ok (Some (`A items)) ->
      List.fold_right
        (fun item acc ->
          match (item, acc) with
          | `String id, Ok ids -> Ok (id :: ids)
          | `String _, Error v -> Error v
          | (`Null | `Bool _ | `Float _ | `A _ | `O _), (Ok _ | Error _) ->
              not_an_id ())
        items (Ok [])
  | Ok (Some (`Null | `Bool _ | `Float _ | `O _)) -> not_an_id ()

let needs_image_job ~job pairs =
  match needed_job_ids ~job pairs with
  | Error v -> [ v ]
  | Ok ids when List.mem image_job ids -> []
  | Ok _ ->
      [
        at_release Needs_image_job
          (Printf.sprintf "job %s does not need %s" job image_job);
      ]

(* [where] names the job or step; [consequence] says what the status-check
   function lets through at that level. *)
let condition ~file ~where ~consequence pairs =
  match field ~file ~where "if" pairs with
  | Error v -> [ v ]
  | Ok None
  | Ok (Some (`Bool _)) ->
      []
  | Ok (Some (`String expression)) when calls_status_function expression ->
      [
        at ~file No_bypass
          (Printf.sprintf "%s: `if: %s` calls a status-check function, so %s"
             where expression consequence);
      ]
  | Ok (Some (`String _)) -> []
  | Ok (Some (`Null | `Float _ | `A _ | `O _)) ->
      [ shape ~file (Printf.sprintf "%s: if is not an expression" where) ]

let continue_on_error ~file ~where ~consequence pairs =
  match field ~file ~where "continue-on-error" pairs with
  | Error v -> [ v ]
  | Ok None
  | Ok (Some (`Bool false)) ->
      []
  | Ok (Some (`Bool true | `Null | `Float _ | `String _ | `A _ | `O _)) ->
      [
        at ~file No_bypass
          (Printf.sprintf "%s: continue-on-error is set, so %s" where
             consequence);
      ]

(* One step of a job: [where] names it in a violation, [pairs] are its keys. *)
type step = { where : string; pairs : (string * Yaml.value) list }

let step_label index pairs =
  match List.assoc_opt "name" pairs with
  | Some (`String name) -> Printf.sprintf "step %d (%s)" index name
  | Some (`Null | `Bool _ | `Float _ | `A _ | `O _)
  | None ->
      Printf.sprintf "step %d" index

(* Every step must be a mapping. One that is not is refused, and the steps are
   not read at all: an order read past a step it could not place is not the
   job's order. [where] names what holds the steps: a job, or a composite
   action's [runs]. *)
let steps_of ~file ~where pairs =
  match field ~file ~where "steps" pairs with
  | Error v -> Error [ v ]
  | Ok None -> Error [ shape ~file (Printf.sprintf "%s has no steps" where) ]
  | Ok (Some (`Null | `Bool _ | `Float _ | `String _ | `O _)) ->
      Error [ shape ~file (Printf.sprintf "%s: steps is not a list" where) ]
  | Ok (Some (`A items)) -> (
      let read index item =
        match item with
        | `O pairs ->
            Ok
              {
                where = Printf.sprintf "%s, %s" where (step_label index pairs);
                pairs;
              }
        | `Null
        | `Bool _
        | `Float _
        | `String _
        | `A _ ->
            Error
              (shape ~file
                 (Printf.sprintf "%s: step %d is not a mapping" where index))
      in
      let read = List.mapi (fun i item -> read (i + 1) item) items in
      match
        List.filter_map
          (function
            | Error v -> Some v
            | Ok _ -> None)
          read
      with
      | [] ->
          Ok
            (List.filter_map
               (function
                 | Ok step -> Some step
                 | Error _ -> None)
               read)
      | _ :: _ as refused -> Error refused)

let step_bypasses ~file step =
  condition ~file ~where:step.where
    ~consequence:"the step can run after a step before it failed" step.pairs
  @ continue_on_error ~file ~where:step.where
      ~consequence:"a failure there does not stop the steps after it" step.pairs

(* A step that pushes through [docker/build-push-action] has no script line to
   order, so it contributes one line naming the action and, when its [with.push]
   is true, the push. *)
let action_push_line step =
  match List.assoc_opt "uses" step.pairs with
  | Some (`String action)
    when String.starts_with ~prefix:"docker/build-push-action"
           (String.lowercase_ascii action) -> (
      let pushes =
        match List.assoc_opt "with" step.pairs with
        | Some (`O inputs) -> (
            match List.assoc_opt "push" inputs with
            | Some (`Bool true) -> true
            | Some (`String text) ->
                String.equal (String.lowercase_ascii (String.trim text)) "true"
            | Some (`Null | `Bool false | `Float _ | `A _ | `O _)
            | None ->
                false)
        | Some (`Null | `Bool _ | `Float _ | `String _ | `A _)
        | None ->
            false
      in
      match pushes with
      | true -> [ "uses: docker/build-push-action push: true" ]
      | false -> [ "uses: docker/build-push-action" ])
  | Some (`String _ | `Null | `Bool _ | `Float _ | `A _ | `O _)
  | None ->
      []

(* The lines a step's script and action contribute, for deciding whether it is
   one a gate or a verification depends on. *)
let step_lines step =
  (match List.assoc_opt "run" step.pairs with
    | Some (`String text) ->
        List.map String.trim (String.split_on_char '\n' text)
    | Some (`Null | `Bool _ | `Float _ | `A _ | `O _)
    | None ->
        [])
  @ action_push_line step

(* A step the order depends on must run whatever came before it, in a shell
   that stops at the first failure. Any [if] other than a literal [true] can
   skip it, a [shell] key can replace the shell that stops on failure, and a
   [set +e] line turns the stop off for the lines after it. The shell behaviour
   is assumed from documentation, not observed:
   https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax
   (jobs.<job_id>.steps[*].shell). A status-check [if]
   is reported by {!step_bypasses}, so it is not reported twice. *)
let strict_step ~file ~critical step =
  match List.exists critical (step_lines step) with
  | false -> []
  | true ->
      let skipped =
        match List.assoc_opt "if" step.pairs with
        | None
        | Some (`Bool true) ->
            []
        | Some (`String expression)
          when String.equal (String.trim expression) "true"
               || calls_status_function expression ->
            []
        | Some (`Null | `Bool false | `Float _ | `String _ | `A _ | `O _) ->
            [
              at ~file No_bypass
                (Printf.sprintf
                   "%s: this step carries an `if` other than a literal true, \
                    so it can be skipped"
                   step.where);
            ]
      in
      let shell =
        match List.assoc_opt "shell" step.pairs with
        | None -> []
        | Some _ ->
            [
              at ~file No_bypass
                (Printf.sprintf
                   "%s: shell is set, so the step may not stop at the first \
                    failure"
                   step.where);
            ]
      in
      let errexit_off =
        List.filter
          (fun line ->
            Test_helpers.contains ~needle:"set +e" line
            || Test_helpers.contains ~needle:"set +o errexit" line)
          (step_lines step)
      in
      shell
      @ skipped
      @ List.map
          (fun line ->
            at ~file No_bypass
              (Printf.sprintf
                 "%s: `%s` turns off exit on failure for the lines after it"
                 step.where line))
          errexit_off

(* One line of a job's run scripts. [order] numbers the lines of every step of
   the job in the order they run, so one line runs before another exactly when
   its order is lower. *)
type line = { order : int; at_step : string; text : string }

(* The lines of each step's [run] script, trimmed, in the order they run. A step
   with no [run] contributes none. *)
let lines_of ~file steps =
  let script step =
    match field ~file ~where:step.where "run" step.pairs with
    | Error v -> Error v
    | Ok None ->
        Ok (List.map (fun line -> (step.where, line)) (action_push_line step))
    | Ok (Some (`String text)) ->
        Ok
          (List.map
             (fun line -> (step.where, String.trim line))
             (String.split_on_char '\n' text)
          @ List.map (fun line -> (step.where, line)) (action_push_line step))
    | Ok (Some (`Null | `Bool _ | `Float _ | `A _ | `O _)) ->
        Error
          (shape ~file (Printf.sprintf "%s: run is not a script" step.where))
  in
  let scripts = List.map script steps in
  match
    List.filter_map
      (function
        | Error v -> Some v
        | Ok _ -> None)
      scripts
  with
  | [] ->
      Ok
        (List.concat_map
           (function
             | Ok lines -> lines
             | Error _ -> [])
           scripts
        |> List.mapi (fun order (at_step, text) -> { order; at_step; text }))
  | _ :: _ as refused -> Error refused

let words text =
  String.split_on_char ' ' text
  |> List.concat_map (String.split_on_char '\t')
  |> List.filter (fun word -> not (String.equal word ""))

(* A line counts as running a check only when the line's status is the check's.
   A pipe, a list or a background operator after it can turn the check's
   failure into a success the step never sees. *)
let shell_operator word =
  String.exists
    (fun c -> Char.equal c '|' || Char.equal c '&' || Char.equal c ';')
    word

let runs_recipe recipe text =
  match words text with
  | "just" :: name :: args ->
      String.equal name recipe && not (List.exists shell_operator args)
  | []
  | _ :: _ ->
      false

(* Bare [just] runs the default recipe, which is the whole local gate: build,
   test, fmt, lint and the server image check. Any narrower recipe leaves part
   of it unrun. *)
let runs_full_gate text =
  match words text with
  | [ "just" ] -> true
  | []
  | _ :: _ ->
      false

(* A push is recognised wherever the command appears on a line, so a push
   written in an unexpected way is still held to the order rather than missed. *)
let pushes_image text =
  let has needle = Test_helpers.contains ~needle text in
  has "docker push"
  || has "just push-server"
  || has "docker image push"
  || has "docker buildx imagetools create"
  || (has "docker buildx build" && has "--push")
  || (has "docker/build-push-action" && has "push: true")

let pushes_tag text =
  let has needle = Test_helpers.contains ~needle text in
  has "git push" || has "gh release create" || (has "gh api" && has "git/refs")

(* The steps that prove the image before anything is pushed, in the order the
   release runs them. *)
let verifications =
  [
    "check-version-floor";
    "verify-server-image";
    "verify-server-image-negative";
    "check-server-image";
  ]

let latest_after_verify lines =
  let first_run recipe =
    List.find_opt (fun line -> runs_recipe recipe line.text) lines
  in
  let absent =
    List.filter_map
      (fun recipe ->
        match first_run recipe with
        | Some _ -> None
        | None ->
            Some
              (at_release Latest_after_verify
                 (Printf.sprintf
                    "job %s: no step runs just %s, so the push does not wait \
                     on it"
                    image_job recipe)))
      verifications
  in
  let early push =
    let pending =
      List.filter
        (fun recipe ->
          match first_run recipe with
          | Some verified -> verified.order > push.order
          | None -> false)
        verifications
    in
    match pending with
    | [] -> None
    | _ :: _ ->
        Some
          (at_release Latest_after_verify
             (Printf.sprintf "%s: `%s` runs before these have passed: %s"
                push.at_step push.text
                (String.concat ", " (List.map (fun r -> "just " ^ r) pending))))
  in
  match List.filter (fun line -> pushes_image line.text) lines with
  | [] ->
      [
        shape ~file:release_file
          ("job " ^ image_job ^ ": no step pushes the image");
      ]
  | _ :: _ as pushes -> absent @ List.filter_map early pushes

let image_job_checks pairs =
  let file = release_file in
  let job_level =
    continue_on_error ~file ~where:("job " ^ image_job)
      ~consequence:"its failure is not the failure the jobs needing it wait on"
      pairs
  in
  match steps_of ~file ~where:("job " ^ image_job) pairs with
  | Error refused -> job_level @ refused
  | Ok steps -> (
      let critical line =
        pushes_image line
        || List.exists (fun recipe -> runs_recipe recipe line) verifications
      in
      let bypasses =
        List.concat_map (step_bypasses ~file) steps
        @ List.concat_map (strict_step ~file ~critical) steps
      in
      match lines_of ~file steps with
      | Error refused -> job_level @ bypasses @ refused
      | Ok lines -> job_level @ bypasses @ latest_after_verify lines)

let check_release_jobs jobs =
  match
    ( job_named ~file:release_file jobs image_job,
      job_named ~file:release_file jobs "release",
      job_named ~file:release_file jobs "update-homebrew-tap" )
  with
  | Ok server, Ok release, Ok tap ->
      let publishing = [ ("release", release); ("update-homebrew-tap", tap) ] in
      List.concat_map
        (fun (job, pairs) -> needs_image_job ~job pairs)
        publishing
      @ List.concat_map
          (fun (job, pairs) ->
            condition ~file:release_file ~where:("job " ^ job)
              ~consequence:"the job can run after a job it needs failed" pairs)
          publishing
      @ image_job_checks server
  | server, release, tap ->
      List.filter_map
        (function
          | Ok _ -> None
          | Error v -> Some v)
        [ server; release; tap ]

(* The action a step runs, if it runs one. *)
let action_of ~file step =
  match field ~file ~where:step.where "uses" step.pairs with
  | Error v -> Error v
  | Ok None -> Ok None
  | Ok (Some (`String action)) -> Ok (Some action)
  | Ok (Some (`Null | `Bool _ | `Float _ | `A _ | `O _)) ->
      Error
        (shape ~file
           (Printf.sprintf "%s: uses is not an action reference" step.where))

(* action-gh-release creates the tag it is given when the tag does not exist,
   and the release with it. Assumed from documentation, not observed:
   https://github.com/softprops/action-gh-release#inputs (tag_name). *)
let creates_release ~file step =
  match action_of ~file step with
  | Error v -> Error v
  | Ok None -> Ok false
  | Ok (Some action) ->
      Ok
        (String.starts_with ~prefix:"softprops/action-gh-release@"
           (String.lowercase_ascii action))

(* A step's [with] inputs. A step with none has none; a [with] that is not a
   mapping is refused rather than read as empty. *)
let step_inputs ~file step =
  match field ~file ~where:step.where "with" step.pairs with
  | Error v -> Error v
  | Ok None -> Ok []
  | Ok (Some (`O inputs)) -> Ok inputs
  | Ok (Some (`Null | `Bool _ | `Float _ | `String _ | `A _)) ->
      Error
        (shape ~file (Printf.sprintf "%s: with is not a mapping" step.where))

let string_input ~file step inputs name =
  match field ~file ~where:step.where name inputs with
  | Error v -> Error v
  | Ok None -> Ok None
  | Ok (Some (`String value)) -> Ok (Some value)
  | Ok (Some (`Null | `Bool _ | `Float _ | `A _ | `O _)) ->
      Error
        (shape ~file
           (Printf.sprintf "%s: input %s is not a string" step.where name))

let is_checkout action =
  String.starts_with ~prefix:"actions/checkout@" (String.lowercase_ascii action)

(* A checkout given a [token] persists it in the repository's git config, where
   every later step of the job can read it. Assumed from documentation, not
   observed: https://github.com/actions/checkout#usage (token,
   persist-credentials). A step whose [uses] cannot be read
   is reported by [creates_release] in the same job, so it is not reported
   twice here. *)
let checkout_token ~file step =
  match action_of ~file step with
  | Error _
  | Ok None ->
      []
  | Ok (Some action) -> (
      match is_checkout action with
      | false -> []
      | true -> (
          match step_inputs ~file step with
          | Error v -> [ v ]
          | Ok inputs -> (
              match List.mem_assoc "token" inputs with
              | false -> []
              | true ->
                  [
                    at ~file Credential_scope
                      (Printf.sprintf
                         "%s: the checkout is given a token, which persists in \
                          the repository's git config for every later step of \
                          the job"
                         step.where);
                  ])))

(* A job's tag-creating steps and what the rule finds wrong with them. [cuts]
   is whether the job creates a tag at all. *)
type tag_job = { cuts : bool; found : violation list }

let tag_job ~file ~job pairs =
  match steps_of ~file ~where:("job " ^ job) pairs with
  | Error refused -> { cuts = false; found = refused }
  | Ok steps -> (
      let releases =
        List.map (fun step -> (step, creates_release ~file step)) steps
      in
      let release_violations =
        List.filter_map
          (fun (step, creates) ->
            match creates with
            | Error v -> Some v
            | Ok false -> None
            | Ok true ->
                Some
                  (at ~file Tag_after_gate
                     (Printf.sprintf
                        "%s: action-gh-release creates the tag and the GitHub \
                         release here, before the image for that version \
                         exists"
                        step.where)))
          releases
      in
      let creates_any =
        List.exists
          (fun (_, creates) ->
            match creates with
            | Ok true -> true
            | Ok false
            | Error _ ->
                false)
          releases
      in
      let credentials = List.concat_map (checkout_token ~file) steps in
      match lines_of ~file steps with
      | Error refused ->
          {
            cuts = creates_any;
            found = release_violations @ credentials @ refused;
          }
      | Ok lines ->
          let gate =
            List.find_opt (fun line -> runs_full_gate line.text) lines
          in
          let tag_pushes =
            List.filter (fun line -> pushes_tag line.text) lines
          in
          let ungated =
            List.filter_map
              (fun push ->
                match gate with
                | Some gate when gate.order < push.order -> None
                | Some _
                | None ->
                    Some
                      (at ~file Tag_after_gate
                         (Printf.sprintf
                            "%s: `%s` runs with no bare `just` step before it, \
                             so the tag can be cut without the full gate \
                             having passed"
                            push.at_step push.text)))
              tag_pushes
          in
          let cuts =
            creates_any
            ||
            match tag_pushes with
            | [] -> false
            | _ :: _ -> true
          in
          let bypasses =
            match cuts with
            | true ->
                let critical line = pushes_tag line || runs_full_gate line in
                List.concat_map (step_bypasses ~file) steps
                @ List.concat_map (strict_step ~file ~critical) steps
            | false -> []
          in
          {
            cuts;
            found = release_violations @ credentials @ ungated @ bypasses;
          })

let check_main_jobs jobs =
  let file = main_file in
  let read =
    List.map
      (fun (job, body) ->
        match body with
        | `O pairs -> tag_job ~file ~job pairs
        | `Null
        | `Bool _
        | `Float _
        | `String _
        | `A _ ->
            {
              cuts = false;
              found =
                [ shape ~file (Printf.sprintf "job %s is not a mapping" job) ];
            })
      jobs
  in
  let found = List.concat_map (fun job -> job.found) read in
  match List.exists (fun job -> job.cuts) read with
  | true -> found
  | false ->
      found
      @ [
          shape ~file
            "no step pushes a tag with git push or creates one with \
             action-gh-release";
        ]

let with_jobs ~file check doc =
  match doc with
  | `O top -> (
      match field ~file ~where:"the workflow" "jobs" top with
      | Error v -> [ v ]
      | Ok (Some (`O jobs)) -> check jobs
      | Ok (Some (`Null | `Bool _ | `Float _ | `String _ | `A _)) ->
          [ shape ~file "jobs is not a mapping of job ids to jobs" ]
      | Ok None -> [ shape ~file "the workflow has no jobs" ])
  | `Null
  | `Bool _
  | `Float _
  | `String _
  | `A _ ->
      [ shape ~file "the workflow is not a mapping" ]

let check_release doc = with_jobs ~file:release_file check_release_jobs doc
let check_main doc = with_jobs ~file:main_file check_main_jobs doc
let is_lower_hex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')

(* Git prints a commit SHA as forty lowercase hexadecimal digits. Anything
   shorter is a prefix the remote resolves, so it names no fixed commit. *)
let is_full_sha reference =
  String.length reference = 40 && String.for_all is_lower_hex reference

(* A pin is moved by resolving the new tag to its commit, never by typing a tag:
   [git ls-remote https://github.com/<owner>/<repo> refs/tags/<tag>] prints the
   SHA, and an annotated tag also prints a [<tag>^{}] line whose SHA is the
   commit to use. Keep the tag as a trailing comment on the [uses] line.

   [owner/repo[/path]@<sha>]. The path names an action inside the repository;
   the SHA fixes the whole repository, so it fixes the path too. *)
let is_pinned action =
  match String.split_on_char '@' action with
  | [ path; reference ] -> (
      match String.split_on_char '/' path with
      | owner :: repo :: _ ->
          (not (String.equal owner ""))
          && (not (String.equal repo ""))
          && is_full_sha reference
      | []
      | [ _ ] ->
          false)
  | []
  | [ _ ]
  | _ :: _ :: _ :: _ ->
      false

(* A [./] reference is a file in the checkout the job already runs from, so
   there is no remote name for it to drift under. *)
let is_local action = String.starts_with ~prefix:"./" action

let step_pin ~file step =
  match action_of ~file step with
  | Error v -> [ v ]
  | Ok None -> []
  | Ok (Some action) when is_local action || is_pinned action -> []
  | Ok (Some action) ->
      [
        at ~file Pinned_action
          (Printf.sprintf "%s: `%s` is not pinned to a full-length commit SHA"
             step.where action);
      ]

(* GitHub substitutes a [${{ }}] expression into a [run] script as text before
   the shell reads it, so a value the expression yields is parsed as shell. The
   same value bound under [env] arrives as a variable and is never parsed. That
   substitution is assumed from documentation, not observed:
   https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#understanding-the-risk-of-script-injections *)
let step_run_expression ~file step =
  match List.assoc_opt "run" step.pairs with
  | Some (`String script) when Test_helpers.contains ~needle:"${{" script ->
      [
        at ~file Run_expression
          (Printf.sprintf
             "%s: the run script holds a `${{` expression, which is \
              substituted into the script text before the shell reads it; bind \
              it under env and read the variable"
             step.where);
      ]
  | Some (`String _ | `Null | `Bool _ | `Float _ | `A _ | `O _)
  | None ->
      []

let pins_in_steps ~file ~where pairs =
  match steps_of ~file ~where pairs with
  | Error refused -> refused
  | Ok steps ->
      List.concat_map
        (fun step -> step_pin ~file step @ step_run_expression ~file step)
        steps

let pins_in_jobs ~file jobs =
  List.concat_map
    (fun (job, body) ->
      match body with
      | `O pairs -> pins_in_steps ~file ~where:("job " ^ job) pairs
      | `Null
      | `Bool _
      | `Float _
      | `String _
      | `A _ ->
          [ shape ~file (Printf.sprintf "job %s is not a mapping" job) ])
    jobs

(* A workflow holds [jobs]; a composite action holds [runs]. A document holding
   both or neither is not one the rule knows how to read. *)
let check_uses ~file doc =
  let where = "the document" in
  match doc with
  | `O top -> (
      match (field ~file ~where "jobs" top, field ~file ~where "runs" top) with
      | Error jobs, Error runs -> [ jobs; runs ]
      | Error v, Ok _
      | Ok _, Error v ->
          [ v ]
      | Ok (Some (`O jobs)), Ok None -> pins_in_jobs ~file jobs
      | Ok (Some (`Null | `Bool _ | `Float _ | `String _ | `A _)), Ok None ->
          [ shape ~file "jobs is not a mapping of job ids to jobs" ]
      | Ok None, Ok (Some (`O runs)) -> pins_in_steps ~file ~where:"runs" runs
      | Ok None, Ok (Some (`Null | `Bool _ | `Float _ | `String _ | `A _)) ->
          [ shape ~file "runs is not a mapping" ]
      | Ok (Some _), Ok (Some _) ->
          [
            shape ~file
              "the document has both jobs and runs, so it is neither a \
               workflow nor an action";
          ]
      | Ok None, Ok None ->
          [
            shape ~file
              "the document has neither jobs (a workflow) nor runs (a \
               composite action)";
          ])
  | `Null
  | `Bool _
  | `Float _
  | `String _
  | `A _ ->
      [ shape ~file "the document is not a mapping" ]

let dockerfile = "Dockerfile"

(* [sha256:] and sixty-four lowercase hexadecimal digits, the form a registry
   gives a content digest in. *)
let is_sha256_digest digest =
  match String.split_on_char ':' digest with
  | [ "sha256"; hex ] ->
      String.length hex = 64 && String.for_all is_lower_hex hex
  | []
  | [ _ ]
  | _ :: _ :: _ ->
      false

(* [<image>[:<tag>]@<digest>]. A digest names one image's content, so the
   registry cannot serve a different one under it; a tag can be moved. *)
let is_digested image =
  match String.split_on_char '@' image with
  | [ name; digest ] -> (not (String.equal name "")) && is_sha256_digest digest
  | []
  | [ _ ]
  | _ :: _ :: _ :: _ ->
      false

let rec drop_flags = function
  | word :: rest when String.starts_with ~prefix:"--" word -> drop_flags rest
  | ([] | _ :: _) as words -> words

(* Docker reads instruction keywords and stage names without regard to case, so
   both are compared lowercased here: a [from] or an [as] written in lowercase
   is the same instruction and is held to the same rule. *)
let lower = String.lowercase_ascii

(* [scratch] is Docker's reserved name for the empty image: nothing is pulled,
   so there is no content for a digest to name. *)
let is_scratch image = String.equal (lower image) "scratch"

(* The image a FROM line starts from, and the stage name it declares if any. *)
let from_operands words =
  match drop_flags words with
  | [ image ] -> Some (image, None)
  | [ image; keyword; name ] when String.equal (lower keyword) "as" ->
      Some (image, Some name)
  | []
  | _ :: _ ->
      None

(* What the lines read so far have established: the stage names declared,
   whether any FROM was seen, and the violations found. *)
type dockerfile_scan = {
  stages : string list;
  seen_from : bool;
  found : violation list;
}

(* A line is a FROM instruction when its first word is the keyword. A comment
   starts with [#], so a FROM quoted in one is not read as an instruction. *)
let scan_line scan (number, line) =
  match words (String.trim line) with
  | keyword :: operands when String.equal (lower keyword) "from" -> (
      let scan = { scan with seen_from = true } in
      match from_operands operands with
      | None ->
          let v =
            shape ~file:dockerfile
              (Printf.sprintf
                 "line %d: FROM is not `FROM [--flag ...] <image> [AS <name>]`"
                 number)
          in
          { scan with found = v :: scan.found }
      | Some (image, declared) ->
          let found =
            match
              List.mem (lower image) scan.stages
              || is_digested image
              || is_scratch image
            with
            | true -> scan.found
            | false ->
                at ~file:dockerfile Digested_base
                  (Printf.sprintf
                     "line %d: `%s` is not pinned to a sha256 content digest"
                     number image)
                :: scan.found
          in
          let stages =
            Option.to_list (Option.map lower declared) @ scan.stages
          in
          { scan with stages; found })
  | []
  | _ :: _ ->
      scan

let check_dockerfile text =
  let scan =
    String.split_on_char '\n' text
    |> List.mapi (fun index line -> (index + 1, line))
    |> List.fold_left scan_line { stages = []; seen_from = false; found = [] }
  in
  match scan.seen_from with
  | true -> List.rev scan.found
  | false ->
      [
        shape ~file:dockerfile
          "the file has no FROM instruction, so it names no base image";
      ]

(* Every job that creates a GitHub release, and whether any step of the
   workflow does. A job whose steps cannot be read is refused: a release
   created in a step the rule could not place is not known to follow the image. *)
let release_creation_in_job ~job pairs =
  let file = release_file in
  match steps_of ~file ~where:("job " ^ job) pairs with
  | Error refused -> (false, refused)
  | Ok steps -> (
      let results = List.map (creates_release ~file) steps in
      let unreadable =
        List.filter_map
          (function
            | Error v -> Some v
            | Ok _ -> None)
          results
      in
      let creating =
        List.exists
          (function
            | Ok true -> true
            | Ok false
            | Error _ ->
                false)
          results
      in
      match creating with
      | false -> (false, unreadable)
      | true -> (
          match needed_job_ids ~job pairs with
          | Error v -> (true, unreadable @ [ v ])
          | Ok ids when List.mem image_job ids -> (true, unreadable)
          | Ok _ ->
              ( true,
                unreadable
                @ [
                    at_release Needs_image_job
                      (Printf.sprintf
                         "job %s creates the GitHub release but does not need \
                          %s, so a release can exist for a version whose image \
                          did not publish"
                         job image_job);
                  ] )))

let check_release_creation_jobs jobs =
  let file = release_file in
  let read =
    List.map
      (fun (job, body) ->
        match body with
        | `O pairs -> release_creation_in_job ~job pairs
        | `Null
        | `Bool _
        | `Float _
        | `String _
        | `A _ ->
            ( false,
              [ shape ~file (Printf.sprintf "job %s is not a mapping" job) ] ))
      jobs
  in
  let found = List.concat_map snd read in
  match List.exists fst read with
  | true -> found
  | false ->
      found
      @ [
          shape ~file
            "no step creates the GitHub release with action-gh-release";
        ]

let check_release_creation doc =
  with_jobs ~file:release_file check_release_creation_jobs doc

let tap_repository = "puravida-software/homebrew-bondi"
let tap_job = "update-homebrew-tap-dry-run"
let updater_action = "./.github/actions/update-homebrew-formula"

(* What the steps read so far have established about the tap: the paths it is
   checked out into, how many checkouts there were, whether the updater has
   edited a formula inside one, and the violations found. *)
type tap_scan = {
  tap_paths : string list;
  checkouts : int;
  edits_tap : bool;
  tap_found : violation list;
}

let tap_step scan step =
  let file = dry_run_file in
  let refuse v = { scan with tap_found = v :: scan.tap_found } in
  match action_of ~file step with
  | Error v -> refuse v
  | Ok None -> scan
  | Ok (Some action) -> (
      match step_inputs ~file step with
      | Error v -> refuse v
      | Ok inputs -> (
          match is_checkout action with
          | true -> (
              match
                ( string_input ~file step inputs "repository",
                  string_input ~file step inputs "path" )
              with
              | Error v, _
              | _, Error v ->
                  refuse v
              | Ok repository, Ok path -> (
                  match
                    Option.map String.lowercase_ascii repository
                    = Some tap_repository
                  with
                  | false -> scan
                  | true -> (
                      let scan = { scan with checkouts = scan.checkouts + 1 } in
                      let scan =
                        match List.mem_assoc "token" inputs with
                        | true ->
                            {
                              scan with
                              tap_found =
                                at ~file Tap_dry_run
                                  (Printf.sprintf
                                     "%s: the checkout of the tap is given a \
                                      token, so the dry run is not read-only"
                                     step.where)
                                :: scan.tap_found;
                            }
                        | false -> scan
                      in
                      match path with
                      | Some path ->
                          { scan with tap_paths = path :: scan.tap_paths }
                      | None ->
                          {
                            scan with
                            tap_found =
                              shape ~file
                                (Printf.sprintf
                                   "%s: the checkout of the tap has no path, \
                                    so it would replace the workspace"
                                   step.where)
                              :: scan.tap_found;
                          })))
          | false -> (
              match
                String.equal (String.lowercase_ascii action) updater_action
              with
              | false -> scan
              | true -> (
                  match string_input ~file step inputs "formula-path" with
                  | Error v -> refuse v
                  | Ok None ->
                      refuse
                        (shape ~file
                           (Printf.sprintf "%s: the updater has no formula-path"
                              step.where))
                  | Ok (Some formula) ->
                      let inside =
                        List.exists
                          (fun path ->
                            String.starts_with ~prefix:(path ^ "/") formula)
                          scan.tap_paths
                      in
                      { scan with edits_tap = scan.edits_tap || inside }))))

let check_dry_run_jobs jobs =
  let file = dry_run_file in
  match job_named ~file jobs tap_job with
  | Error v -> [ v ]
  | Ok pairs -> (
      match steps_of ~file ~where:("job " ^ tap_job) pairs with
      | Error refused -> refused
      | Ok steps ->
          let scan =
            List.fold_left tap_step
              {
                tap_paths = [];
                checkouts = 0;
                edits_tap = false;
                tap_found = [];
              }
              steps
          in
          let missing =
            match (scan.checkouts, scan.edits_tap) with
            | 0, _ ->
                [
                  at ~file Tap_dry_run
                    (Printf.sprintf "job %s never checks out the tap" tap_job);
                ]
            | _, false ->
                [
                  at ~file Tap_dry_run
                    (Printf.sprintf
                       "job %s runs no formula update on a formula inside a \
                        tap checkout made before it, so the dry run does not \
                        read the tap's own layout"
                       tap_job);
                ]
            | _, true -> []
          in
          List.rev scan.tap_found @ missing)

let check_dry_run_tap doc = with_jobs ~file:dry_run_file check_dry_run_jobs doc
