The server binary's payload subcommands read their payload from standard input
and leave the failure's class in the exit status. Every command under test here
is run unpiped: a pipe would absorb the status, which is the thing being
asserted. The fixtures are removed first so the file is re-runnable in a
directory a previous run has already written to.

  $ rm -f wrong-shape.json not-json.txt run-payload.json refusal.txt argv.err
  $ rm -f run-refusal.txt help.txt help-flat.txt
  $ rm -f check.json check.err cron-check.json cron-check.err
  $ rm -f idle.out idle.err serve.out serve.err unhandled.err term.out term.err
  $ rm -f int.out int.err

A deploy payload that is JSON of the wrong shape is refused as written. The
message names the field that failed and never the value it carried: a payload
carries registry credentials and environment variables.

  $ cat > wrong-shape.json <<'EOF'
  > {"image": 5}
  > EOF
  $ bondi-server deploy < wrong-shape.json
  invalid deploy payload: Simple.deploy_input.image
  [2]

A body that is not JSON at all is a different refusal, which is what shows that
the bytes on standard input are what was read rather than that deploy refuses
everything. The sentence is matched rather than transcribed, because the rest of
it is the JSON parser's own wording and its byte offsets.

  $ printf 'not json at all' > not-json.txt
  $ bondi-server deploy < not-json.txt 2> refusal.txt
  [2]
  $ grep -c 'invalid JSON' refusal.txt
  1

The run subcommand hands the body to the endpoint as written, which decodes it
for itself, and answers with the same class and the same code. The refusal is
matched out of a captured standard error rather than read inline: run decodes
inside the environment it builds -- it must, because the endpoint decodes for
itself -- and building that environment writes a line of its own to standard
error on any box whose outbound trust store will not load. That line is nothing
this case is about, and inline it would be a diff.

  $ cat > run-payload.json <<'EOF'
  > {"job": "nightly", "image": 5}
  > EOF
  $ bondi-server run < run-payload.json 2> run-refusal.txt
  [2]
  $ grep -c 'invalid run payload: Run.run_payload.image (keys received: job, image)' run-refusal.txt
  1

A payload offered on the command line is not a payload. It is refused before any
subcommand body runs, so the bytes never reach the decoder -- which is the point:
argv is readable by every process on the box. The exit status is asserted as
"not success" rather than against a number, because the number here is the
command-line library's own and changes with its version.

  $ bondi-server deploy '{"image": 5}' 2> argv.err || echo "refused"
  refused
  $ if grep -q 'invalid deploy payload' argv.err; then echo "the argv payload was decoded"; else echo "the argv payload was not decoded"; fi
  the argv payload was not decoded

The check subcommand answers on the built binary, and what it finds is the box
the suite happens to run on: a developer machine has a Docker socket and a CI
runner may not, and neither has a readable PID 1. So the verdict is not what is
asserted -- the exit status is captured into a variable and only its class is
pinned, which is a real claim all the same. It says the binary classified what
it found rather than dying on it: 125 is cmdliner's internal error, 1 is an
exception that escaped, and either would mean `check` never reached a verdict on
this box at all.

Unpiped, for the reason this file opens with. The status is taken by an
assignment rather than by a pipeline, so the command's own status is what lands
in the variable.

  $ bondi-server check > check.json 2> check.err; status=$?
  $ case "$status" in 0|3) echo "the status is a class check chose";; *) echo "unclassified: $status";; esac
  the status is a class check chose
  $ grep -c '"name":"docker_socket"' check.json
  1
  $ grep -c '"name":"diagnostic_sink"' check.json
  1

A deployment that configures no cron is asked about neither the spool nor the
divergence, and the affirmative arm is the same binary on the same box with the
flag set. Without it, a probe that had stopped being taken at all would satisfy
both absences below and this file would go on passing.

  $ if grep -q '"name":"cron_divergence"' check.json; then echo "asked"; else echo "not asked"; fi
  not asked
  $ bondi-server check --cron-configured > cron-check.json 2> cron-check.err; status=$?
  $ case "$status" in 0|3) echo "the status is a class check chose";; *) echo "unclassified: $status";; esac
  the status is a class check chose
  $ if grep -q '"name":"cron_divergence"' cron-check.json; then echo "asked"; else echo "not asked"; fi
  asked
  $ if grep -q '"name":"crontab_spool"' cron-check.json; then echo "asked"; else echo "not asked"; fi
  asked

The manual carries this binary's own exit codes. Cmdliner documents three of its
own and no others unless it is handed a list, and those three are the ones a
classified failure is forbidden to take -- so without the list an operator
reading the manual meets none of the codes the binary actually leaves behind.
Only Bondi's rows are asserted: cmdliner's numbers and its wording are the
library's own and change with its version, which is why the case above declines
to pin one. The page is flattened before it is matched, so that a terminal width
which wraps a row cannot decide whether the row is found, and it is matched
rather than transcribed because the rest of the page is cmdliner's rendering of
a manual this file has no business pinning.

  $ bondi-server --help=plain > help.txt
  $ tr -s ' \n' ' ' < help.txt > help-flat.txt
  $ grep -c '1 on a failure to carry out a well-formed request\.' help-flat.txt
  1
  $ grep -c '2 on a request that was wrong as written\.' help-flat.txt
  1
  $ grep -c '3 on a box that is not ready, which named what is wrong\.' help-flat.txt
  1

The bare binary is what the image's entrypoint runs, and it is what a client
that predates the HTTP surface's deletion still starts an orchestrator with. It
must stay up: a container whose PID 1 exits is a container the runtime reaps. So
what is asserted is that something else had to stop it. It is stopped from
outside after a second, by a signal rather than by the timeout's default: a
process killed by SIGKILL leaves 137, which no exit code this binary or its
command-line library can choose collides with. The timeout's own 124 would --
observed on 2026-09-12, cmdliner's cli_error is 124 as well, so a refusal and a
stopping would have read the same.

The stopping runs inside its own shell, which is not an aesthetic choice: the
shell that runs this file has job control on and announces a foreground job
killed by a signal, with the process id in the line. That line would be a diff
on every run. A shell spawned for the command has no job control and says
nothing, and its own status is the one being read.

  $ sh -c 'timeout -s KILL 1 bondi-server > idle.out 2> idle.err'; status=$?
  $ case "$status" in 137) echo "it was still running when it was stopped";; *) echo "it exited on its own: $status";; esac
  it was still running when it was stopped

It writes nothing while it idles, and a help page least of all: a group that
answered an empty argument list with usage and a non-zero status would stop
every orchestrator already deployed from starting. The two lines are matched
rather than transcribed and their absence is what is asserted -- cmdliner's
wording for both changes with its version, so a file that pinned the text would
fail on a switch upgrade rather than on this binary.

  $ if grep -qE 'Usage:|Try ' idle.out idle.err; then echo "it printed a help page"; else echo "it printed no help page"; fi
  it printed no help page

The serve subcommand left with the HTTP surface. This is also the affirmative
arm for the case above: the same binary run a second way does exit, so "still
running" is a property of the empty argument list rather than of a binary that
hangs whatever it is given. The status is the command-line library's own and is
classified rather than pinned to a number.

  $ sh -c 'timeout -s KILL 5 bondi-server serve > serve.out 2> serve.err'; status=$?
  $ case "$status" in 0) echo "serve was accepted";; 137) echo "serve idled";; *) echo "serve was refused";; esac
  serve was refused

Staying up is not the same as refusing to stop. SIGTERM is how a stop is asked
for -- `docker stop` sends it and waits out the daemon's timeout before falling
back to SIGKILL -- and the orchestrator's process is PID 1 of its container,
where the kernel discards a signal whose disposition is still the default. So
the disposition has to be installed rather than inherited, and what it buys is
the difference between a replacement that takes a moment and one that takes the
full timeout on every version bump.

The status is read from `wait` and not from `timeout`: GNU `timeout` answers 124
whenever it had to signal at all, whatever the command did next, so it cannot
tell a deliberate exit from a death. A backstop SIGKILL follows a second later so
that a binary which ignored the signal ends this file instead of hanging it, and
the three outcomes are classified rather than pinned away -- 0 is the exit the
handler takes, 143 is death by SIGTERM's default action, 137 is the backstop
having been needed.

This runs the binary as an ordinary process, where the default action would
already stop it, so what it pins is which of the three happened and not the PID 1
case, which no test runnable under `dune test` can reach. That case is reached by
`scripts/check-server-image.sh`, which stops a real container whose PID 1 is this
binary and holds the stop to both a deadline and an exit code -- it needs a
Docker Engine, which is why it is a release gate and not a test here.

  $ sh -c 'bondi-server > term.out 2> term.err & pid=$!; sleep 1; kill -TERM $pid; sleep 1; kill -KILL $pid 2> /dev/null; wait $pid'; status=$?
  $ case "$status" in 0) echo "it stopped when it was asked to";; 143) echo "it died of the default action";; 137) echo "it ignored the signal";; *) echo "unclassified: $status";; esac
  it stopped when it was asked to

SIGINT is the other signal an operator sends at this process, and the argument
above does not stop at SIGTERM. `docker kill --signal=INT` sends it, and so does
Ctrl-C on a `docker run` started without `-t`, where `--sig-proxy` forwards the
interrupt to PID 1 -- which is how the `server-docker` recipe in the justfile
runs this binary. [observed -- 2026-09-13, Docker 29.7.2] `docker run --help`
gives `--sig-proxy` as "(default true)", and that recipe passes no `-t`. At the default action the kernel
discards SIGINT at a namespace's init exactly as it discards SIGTERM, so the
container would be stoppable only from a second terminal.

The shape is the SIGTERM arm's, and so is the reading of the status out of
`wait`. The three outcomes differ only in which death is which: 130 is death by
SIGINT's default action, and 137 is again the backstop having been needed.
Backgrounding is what makes 137 the outcome without a disposition here rather
than 130 -- a non-interactive shell sets SIGINT to ignore in a command it starts
with `&` -- and an explicitly installed handler overrides that inherited ignore,
which is the same thing it has to do to the kernel's discard at PID 1.

  $ sh -c 'bondi-server > int.out 2> int.err & pid=$!; sleep 1; kill -INT $pid; sleep 1; kill -KILL $pid 2> /dev/null; wait $pid'; status=$?
  $ case "$status" in 0) echo "it stopped when it was asked to";; 130) echo "it died of the default action";; 137) echo "it ignored the signal";; *) echo "unclassified: $status";; esac
  it stopped when it was asked to

An exception nobody expected is answered with a diagnostic that carries a
backtrace, and the backtrace has to have frames in it. Recording is
process-global and has to be switched on before anything raises, so a handler
that takes the backtrace at the moment of the catch still gets an empty one
unless something earlier turned recording on. Nothing in this binary's own
output would say so: the phrase is written either way, and what is missing is
the line under it.

The exception is induced by closing the standard output the subcommand writes
its answer to, which raises rather than returning a failure -- the one path into
the classification that needs no fixture and no engine. It is asserted at the
binary because the process the unit tests run in has backtrace recording
switched on by the test framework itself, so an assertion made there would pass
against either version of this binary.

  $ bondi-server check >&- 2> unhandled.err
  [1]
  $ grep -c 'a subcommand failed with an unhandled exception: Sys_error' unhandled.err
  1
  $ if grep -qE '^(Raised|Called from|Re-raised|Raised by primitive operation) ' unhandled.err; then echo "the diagnostic carries a frame"; else echo "the diagnostic carries an empty backtrace"; fi
  the diagnostic carries a frame
