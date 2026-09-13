The server binary's payload subcommands read their payload from standard input
and leave the failure's class in the exit status. Every command under test here
is run unpiped: a pipe would absorb the status, which is the thing being
asserted. The fixtures are removed first so the file is re-runnable in a
directory a previous run has already written to.

  $ rm -f wrong-shape.json not-json.txt run-payload.json refusal.txt argv.err
  $ rm -f run-refusal.txt help.txt help-flat.txt
  $ rm -f check.json check.err cron-check.json cron-check.err

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
  $ grep -c '3 on a box that is not in a state to serve\.' help-flat.txt
  1
