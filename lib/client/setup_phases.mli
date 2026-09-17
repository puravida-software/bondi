(** The phases a [bondi setup] run passes through, and what a failure part-way
    through one of them left undone.

    A setup plan is a flat list of actions, but it is built as an ordered
    sequence of phases: Docker, the shared network, cron's [docker] on the
    crontab's own PATH, cron's curl, the ACME file, the orchestrator, alloy, and
    the managed containers. The interpreter applies the list in order and stops
    at the first action that fails, so every phase after that one is skipped —
    and the operator is told only about the action that failed. A run that could
    not start the alloy container reports a container name conflict and says
    nothing about the declared containers it never reached, so a host that is
    part-way through a setup reads as a host that failed at one small thing.

    This module turns "which action failed" into "which phases did not run". It
    performs no I/O and knows nothing about actions: the caller maps its own
    actions onto phases and brings them here, which is what keeps the setup
    command's vocabulary in one place.

    It owns a second register for the same reason. A few of the run's writes are
    read back off the host afterwards, and where the host reports something
    other than what was asked for, the run corrects it — silently, until now, so
    that a run which narrowed a file mode, a run which widened one and a run
    which touched nothing all read alike. {!corrections_report} is that account,
    and the places that can feed it are the constructors of {!site}, each of
    which has to say what it reads and what it reads it off or the module does
    not build.

    What may appear in that account is settled by what {!correction} can hold,
    and the two halves of that are not equally strong. The subject of every line
    — the file, the container — is derived from its {!site} and is one of this
    tool's own constants: there is no subject parameter, so a path or a
    container name read out of a manifest cannot reach a line at all. The value
    the host reported is a {!Host_answer.t}, which is nominal rather than
    checked: nothing stops a caller from declaring a manifest value to be a
    host's answer, but it has to say so, at the one constructor named for that
    boundary. What is left outside either guarantee is the sentence
    {!unreadable_reading} carries, which is a [string] this client words; the
    host's own words reach it through {!Host_answer.t} like everything else, and
    nothing else in it comes from a manifest today. A guarantee that depends on
    recognising a secret fails on the secret nobody recognised, so what is
    claimed here is what the type enforces and not what the current call sites
    happen to pass. *)

(** One phase of a setup run, in the order the plan emits them. Two actions in
    the same phase are one line in a report: an operator recovering a host wants
    to know that alloy did not run, not that four of its actions did not. *)
type phase =
  | Docker
  | Network
  | Cron_docker
  | Cron_curl
  | Acme
  | Orchestrator
  | Alloy
  | Managed

val unfinished_phases : failed:phase -> remaining:phase list -> phase list
(** The phases that a failure in [failed] left unrun, given the phases of the
    actions that were still ahead of it in the plan.

    Each phase is named once and in the order the plan would have reached it.
    [failed] is never among them: the run stopped part-way through that phase
    rather than skipping it, which is a different thing to tell an operator and
    the more alarming of the two. Empty when the failing action was the last in
    the plan. *)

val failure_message :
  server:string ->
  failed:phase ->
  remaining:phase list ->
  reason:string ->
  string
(** The operator-facing report for an action that failed part-way through a
    setup run.

    Carries [reason] — the failure as the host itself reported it — unedited and
    first, then names [server], the phase the run stopped in, and the phases
    that did not run because of it. When nothing was left to run it says so
    rather than omitting the sentence, so a report that lists no skipped phase
    cannot be mistaken for one that forgot to look.

    [server] is named here rather than prefixed onto [reason] because the caller
    prints every server's failure together at the end of a multi-server run, far
    from the line that announced which server was being processed. Naming it
    once, in the sentence this module owns, is what lets each interpreter arm
    return the host's bare words. *)

(** A place where a setup run reads back what the host applied to a write it has
    just made, and so can say what it found.

    Adding a constructor is how a new such place enters the account, and what
    that costs is two exhaustive matches in this module: the reading a site
    reports, and the subject it reads it off. A site added without either does
    not build. What that does not cover, said in the same breath: nothing
    requires a site to be reached, nor a reading to be taken — a write whose
    read-back constructs no correction at all is outside the mechanism, because
    nothing about it reaches this type, and no list here would catch it either.
    The guarantee is that a site which reports has said what it reports and
    about what; it is not a guarantee over the writes a run makes. *)
type site = Alloy_config_mode | Orchestrator_restart_policy

type correction
(** One thing a run's read-back had to say: a divergence it found and corrected,
    or a reading it could not take at all.

    Abstract, and that is where such guarantee as there is lives. What it can
    hold is what the three constructors below put in it: a value the host
    reported about its own state, a value Bondi declares, and a site. Two of
    those are enforced by type. The subject of every line is derived from the
    site rather than passed in, so no caller supplies a path or a container name
    and none can be read out of a manifest into one. The host's value is a
    {!Host_answer.t}, whose one constructor is a named boundary — a caller can
    still declare a manifest value to be a host's answer, but not without
    writing that claim out.

    This is the rule {!Crontab_listing} states for itself, for the same reason
    it states it: a guarantee that depends on recognising a secret fails on the
    secret nobody recognised. Where this one stops is {!unreadable_reading}'s
    [detail], a [string] this client words about a reading it could not take;
    the host's own words reach it through {!Host_answer.t}, and what else it
    says is this client's own sentence.

    The host's own answer is flattened onto one line and bounded as it enters,
    by {!Host_answer.of_host_output} rather than at any render, so there is one
    place a mis-sized answer can be inspected and both registers pass through
    it. That bound is log hygiene and not redaction: an over-long answer is
    carried cut, with how many bytes there were, rather than replaced — the
    answer is the only thing in the line that says what the box actually
    reported. *)

val restart_policy_corrected :
  found:Host_answer.t -> applied:string -> correction
(** The orchestrator container, whose restart policy the host reported as
    [found] and which this run left at [applied].

    [found] is the host's own word for it, bounded as above; [applied] is what
    Bondi asked for. Both are named or nothing is constructed: a line saying
    only what a run changed something to is the reassurance this account exists
    to replace. The container is not a parameter — it is Bondi's own name for
    the one container this site reads, derived from the site. *)

val config_mode_corrected : found:Host_answer.t -> applied:string -> correction
(** The Alloy config file, whose mode the host reported as [found] and which
    this run left at [applied].

    The path is not a parameter either, for the reason above: it is the path
    Bondi declares, which is the only kind of path either site reads. It is
    named in the line because a mode with no file is not a reading. *)

val unreadable_reading : site:site -> detail:string -> correction
(** A site whose reading could not be taken, and why, in this client's words.

    Not a correction — nothing was replaced, and claiming one would report a
    write against a value nobody read — but a line of the same account, because
    a run that could not look reads exactly like a run that looked and found
    agreement, and a line about it printed where it happened is scattered
    through the transcript and lost altogether on the run that stopped after it.
    It says what could not be read and never what was found.

    [detail] is the only value in this module that is neither derived nor a
    {!Host_answer.t}: it is a sentence the caller words, so that one site asking
    one host about one file does not describe a refusal two ways. The host's own
    answer reaches it as a {!Host_answer.t}, bounded, which is what keeps the
    bound a property of the whole account rather than of one of its registers.
*)

val corrections_report : server:string -> correction list -> string list
(** What a run says it changed on one server.

    One line per entry — each is a distinct fact about the box's posture,
    discovered separately, and collapsing two of them into one would throw away
    the values the line exists to print. One line saying nothing diverged
    whenever no entry is a correction, so an empty account and an account never
    taken do not read alike, and so a run that could only say it was unable to
    look is not read as one that found agreement, which is the same reason
    {!failure_message} says "no phase was skipped" rather than omitting the
    sentence. That sentence says only that the list was empty and nothing about
    why: a run that found a divergence and failed before it could correct it
    prints it too, so a clause reading the emptiness as agreement would
    contradict the failure printed beside it.

    [server] is named here, in the sentences this module owns, for the reason
    {!failure_message} names it here: the caller prints every server's account
    together at the end of a multi-server run, far from the line that announced
    which server was being processed.

    Lines, never a verdict. Nothing here decides an exit code, and a correction
    is a write that succeeded — refusing on one would block the command that
    repairs the host. *)
