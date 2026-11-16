(** Static rules over the release path's workflow files.

    The release publishes three things for a version: the server image, the
    client tarball and the Homebrew formula. None of that ordering can be run
    locally, because it is GitHub Actions behaviour. What can be read locally is
    the job graph and the step order that produce it, so these rules read them
    and say where they let a client ship without its image.

    Each rule reads a parsed document in one expected shape. A document in any
    other shape is reported as {!Unexpected_shape}, never passed: a reader that
    stops where it does not recognise the structure checks nothing past that
    point and still reports clean. *)

(** What a violation breaks. *)
type rule =
  | Needs_image_job
      (** The client release and the formula update each depend directly on the
          server image job, so neither runs when the image does not publish. *)
  | No_bypass
      (** No condition or [continue-on-error] lets a job or step run past a
          failure the dependency or the step order exists to stop at, and no
          step the order depends on can be skipped or run in a shell that does
          not stop at the first failure. *)
  | Tag_after_gate
      (** The tag is pushed only after the full local gate has passed. *)
  | Latest_after_verify
      (** The image is pushed only after every step that verifies it. *)
  | Pinned_action
      (** A remote action is referenced by a full-length commit SHA. *)
  | Run_expression
      (** No [run] script holds a [${{ }}] expression: a value is bound under
          [env] and read as a variable. *)
  | Digested_base  (** Every external base image carries a content digest. *)
  | Credential_scope
      (** A write credential is not handed to a step that persists it for the
          steps after it. *)
  | Tap_dry_run
      (** The release dry run reads the tap's own formula, with no credential.
      *)
  | Unexpected_shape  (** The document is not in the shape the rule reads. *)

type violation = {
  file : string;  (** The file the violation was found in. *)
  rule : rule;  (** The rule it breaks. *)
  detail : string;  (** Where it was found and what was there. *)
}
(** One place a file breaks one rule. *)

val check_release : Yaml.value -> violation list
(** [check_release doc] is every violation of {!Needs_image_job}, {!No_bypass},
    {!Latest_after_verify} and {!Unexpected_shape} in the release workflow
    [doc]; [[]] when it has none. Each one's [file] is
    [.github/workflows/release.yaml].

    [release] and [update-homebrew-tap] must each name [release-server] in
    [needs], given as a string or a list of strings. Neither job may carry an
    [if] that calls a status-check function ([success], [failure], [always],
    [cancelled]): without one, GitHub runs a job only when everything it needs
    succeeded, and with one, the expression alone decides. For the same reason,
    no step of [release-server] may carry such an [if], and neither the job nor
    any of its steps may set [continue-on-error] to anything but [false].

    Steps are identified by the command their [run] script holds, never by their
    display name. A line runs a check when its words are [just], the recipe, and
    arguments carrying no [|], [&] or [;] that could swallow the check's
    failure. In [release-server], every line pushing the image ([docker push] or
    [just push-server] anywhere in it) must come after a line running each of
    [just check-version-floor], [just verify-server-image],
    [just verify-server-image-negative] and [just check-server-image]. A check
    that runs nowhere is reported once, and a job that pushes nothing is
    {!Unexpected_shape}.

    A step holding a verification or a push is also held to this: its [if], if
    it has one, must be a literal [true] (or a status-check [if], reported as
    above); it may carry no [shell] key; and no line of its script may be
    [set +e] or [set +o errexit]. A push is also recognised in the forms
    [docker image push], [docker buildx imagetools create],
    [docker buildx build --push] and a [docker/build-push-action] step whose
    [with.push] is true. *)

val check_main : Yaml.value -> violation list
(** [check_main doc] is every violation of {!Tag_after_gate}, {!No_bypass} and
    {!Unexpected_shape} in the main workflow [doc]; [[]] when it has none. Each
    one's [file] is [.github/workflows/main.yaml].

    The tag starts the release, so it may only be cut once the whole local gate
    has passed. Every line pushing a tag ([git push] anywhere in it) must come
    after a line, earlier in the same job, that is bare [just] alone: the
    default recipe, which is the only one that runs build, test, fmt, lint and
    the image check together. No step may use [softprops/action-gh-release],
    which creates the tag and the GitHub release before the image for that
    version exists. A tag is also pushed by [gh release create] and by [gh api]
    on [git/refs], and these are held to the gate as [git push] is. In a job
    that cuts a tag, no step may carry a status-check [if] or set
    [continue-on-error], as in {!check_release}; the gate step and every step
    pushing a tag are also held to the literal-[true] [if], no-[shell] and
    no-[set +e] rules of {!check_release}. No [actions/checkout] step may be
    given a [token] in its [with]: the checkout persists it in the repository's
    git config for every later step of the job, so a write credential is a
    {!Credential_scope} violation there and belongs under [env] in the one step
    that needs it. A workflow in which no step cuts a tag either way is
    {!Unexpected_shape}: the rule has nothing to hold to the gate. *)

val check_release_creation : Yaml.value -> violation list
(** [check_release_creation doc] is every violation of {!Needs_image_job} and
    {!Unexpected_shape} in the release workflow [doc]; [[]] when it has none.
    Each one's [file] is [.github/workflows/release.yaml].

    A step using [softprops/action-gh-release] (read in any case) creates the
    tag it is given and the GitHub release with it. Every job holding one must
    name [release-server] in [needs], so the release is created only once its
    image has published. A job whose steps cannot be read, or a workflow in
    which no step creates the release, is {!Unexpected_shape}. Only
    [action-gh-release] is read: whether the release carries generated notes is
    a product choice and is not a rule. *)

val check_dry_run_tap : Yaml.value -> violation list
(** [check_dry_run_tap doc] is every violation of {!Tap_dry_run} and
    {!Unexpected_shape} in the dry-run workflow [doc]; [[]] when it has none.
    Each one's [file] is [.github/workflows/release-dry-run.yaml].

    The release rewrites the tap's own formula, which is laid out differently
    from this repository's copy, so a dry run over the copy alone passes where
    the release is refused. Job [update-homebrew-tap-dry-run] must therefore
    check out [puravida-software/homebrew-bondi] (the repository name is read in
    any case) into a [path], with no [token], and then run
    [./.github/actions/update-homebrew-formula] with a [formula-path] inside
    that path, in a step after the checkout. The path test is a textual prefix:
    a [formula-path] spelled any other way is not read as inside. A job missing
    from the workflow, a checkout of the tap with no [path], an updater with no
    [formula-path], or an input that is not a string is {!Unexpected_shape}. *)

val check_uses : file:string -> Yaml.value -> violation list
(** [check_uses ~file doc] is every violation of {!Pinned_action},
    {!Run_expression} and {!Unexpected_shape} in [doc], a workflow or a
    composite action; [[]] when it has none. Each one's [file] is [file].

    A tag is a name the action's owner can move, so a tag reference runs
    whatever code the tag points at on the day the job starts, in a job that may
    hold the release's secrets. Only a commit SHA names one fixed tree. Every
    [uses] must therefore be [owner/repo[/path]@<sha>], where [<sha>] is forty
    lowercase hexadecimal digits: an abbreviated SHA is a prefix the remote
    resolves, not a fixed name. A local reference, starting with [./], names a
    file in the same checkout and is exempt. Anything else, including a
    [docker://] reference, is a {!Pinned_action} violation.

    A workflow is read through [jobs.<id>.steps[].uses], a composite action
    through [runs.steps[].uses]. A document with neither [jobs] nor [runs], or
    with both, is {!Unexpected_shape}, as is a job or a [runs] with no steps:
    the rule reads step references only, so a job calling a reusable workflow,
    or a JavaScript or Docker action, is refused rather than passed unread.

    The same steps are read for a [run] script containing [${{]. GitHub
    substitutes the expression into the script text before the shell parses it,
    so a value it yields can inject commands; every such step is a
    {!Run_expression} violation, however the expression is spelt inside. A
    [${{ }}] under [env] or [with] is not read. *)

val check_dockerfile : string -> violation list
(** [check_dockerfile text] is every violation of {!Digested_base} and
    {!Unexpected_shape} in the Dockerfile [text]; [[]] when it has none. Each
    one's [file] is [Dockerfile].

    [FROM scratch] (read in any case) is exempt: it is Docker's empty image, so
    nothing is pulled for a digest to name. An image built from a build argument
    ([ARG BASE=...] then [FROM $BASE]) is refused on purpose: the name held by
    the [FROM] is [$BASE], which carries no digest, and the rule reads no [ARG]
    to resolve it. Write the digest in the [FROM].

    A tag is a name the registry can point at different content from one day to
    the next, so a base image named by its tag alone lets the same commit build
    on a different base. Only a digest names one image's content. Every [FROM]
    must therefore name [<image>[:<tag>]@sha256:<digest>], where [<digest>] is
    sixty-four lowercase hexadecimal digits. A [FROM] naming a stage declared by
    an earlier [FROM ... AS <name>] builds on that stage, not on a registry
    image, and is exempt; a name declared only further down is an image and is
    held to the rule.

    The [FROM] keyword and the [AS] keyword are read in any case, as Docker
    reads them, and leading [--flag] words such as [--platform] are skipped. A
    [FROM] whose remaining words are not an image and an optional [AS <name>] is
    {!Unexpected_shape}, as is a file with no [FROM] at all. Only [FROM] is
    read: an image named by [COPY --from] or [RUN --mount=from] is not checked.
*)
