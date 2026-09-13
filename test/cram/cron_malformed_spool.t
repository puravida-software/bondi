One spool file, two commands, opposite outcomes.

A crontab whose BEGIN/END markers do not balance is a file with no unambiguous
Bondi section in it, and the two halves of Bondi treat that differently on
purpose. A deploy is refused, because rewriting a section whose extent nobody
can determine means guessing where Bondi's half ends and an operator's begins.
A setup proceeds, because what it does to the cron payload directory is copy
files out of a container that is about to be recreated, and copying files is
safe on a crontab nobody is about to rewrite -- while refusing would strand the
job's run file and its secret environment file in a layer the recreate deletes,
on exactly the hosts whose crontab is already broken.

Both behaviours are pinned on their own side. What nothing in this repository
did until this file is put one spool in front of both, and the divergence is the
assertion: a later change that "helpfully" made setup refuse as well would break
payload preservation on precisely the hosts that need it, and every test that
exists would still be green.

The fixtures are removed first so the file is re-runnable in a directory a
previous run has already written to.

  $ ROOT="$PWD"
  $ rm -f spool.txt before.md5 after.md5 deploy.log setup.log ssh-argv.log

The spool. An end marker closes a section that was never opened -- the file also
holds a line of an operator's own, above the marker, which is what makes the
extent of Bondi's half genuinely unknowable rather than merely empty.

  $ cat > spool.txt <<'SPOOL'
  > SHELL=/bin/sh
  > 0 5 * * * /usr/local/bin/rotate-logs
  > # END BONDI CRON
  > SPOOL
  $ export SPOOL="$ROOT/spool.txt"
  $ md5sum < "$SPOOL" > before.md5

The stub answers as the box, and serves both commands below unchanged. The
crontab arm prints the fixture between the markers the read's own command
prints, so what reaches the client is the same stream a real host would send.

The deploy arm is the box's refusal, transcribed. The verdict is the
orchestrator's -- it is the orchestrator that reads the spool and declines to
rewrite it -- and the client that carries it here decodes nothing and takes the
exit code as the whole of the answer, so what this arm pins is the client's
half: that a non-zero exit is not swallowed and the box's own words are what
the operator is shown. The sentence itself is a transcription and will not
redden if the orchestrator's wording changes.

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > case "$1" in
  >   'docker --version') echo 'Docker version 27.0.0, build deadbeef' ;;
  >   *BONDI_CRON_DOCKER_PRESENT*) echo 'BONDI_CRON_DOCKER_PRESENT /usr/bin/docker' ;;
  >   'curl --version') echo 'curl 8.5.0 (x86_64-pc-linux-gnu) libcurl/8.5.0' ;;
  >   # The three readings setup takes off the box after it starts the
  >   # container: the wait for a running state, the server's own check inside
  >   # it, and a read of the container's log stream for the line the check
  >   # writes to its diagnostic sink. The check writes a document and the log
  >   # read carries the marker because an empty answer is a rejection rather
  >   # than a pass, and a rejection here would stop the run before the payload
  >   # copy this file is about.
  >   'attempt=0; while'*) : ;;
  >   *'bondi-server check'*) echo '{"ready":true,"observations":[]}' ;;
  >   'docker logs --tail'*) echo 'bondi check: diagnostic sink is writable' ;;
  >   *'/var/spool/cron/crontabs/root'*)
  >     echo BONDI_CRONTAB_CONTENTS
  >     cat "$SPOOL"
  >     echo BONDI_CRONTAB_END ;;
  >   *'PortBindings'*) echo '127.0.0.1' ;;
  >   *'docker cp'*) : ;;
  >   *'RestartPolicy'*) echo unless-stopped ;;
  >   *BONDI_CRON_PAYLOAD_LISTED*)
  >     echo BONDI_CRON_PAYLOAD_LISTED
  >     echo /etc/bondi/cron/nightly-report/run.json
  >     echo /etc/bondi/cron/nightly-report/env
  >     echo BONDI_CRON_PAYLOAD_END ;;
  >   # The orchestrator running at the declared version, which is the state that
  >   # makes setup a recreate -- and a recreate is what the payload copy exists
  >   # to survive. Without this arm the listing falls through to *) and answers
  >   # nothing, which reads as a host with no orchestrator at all: nothing to
  >   # copy out of, so nothing planned, and the divergence this file is about
  >   # would go untested while the run still exited zero.
  >   *'name=^/bondi-orchestrator$'*'{{.State}}'*)
  >     printf 'running\tmlopez1506/bondi-server:0.20.0\n' ;;
  >   # The orchestrator's image on its own, which is the version both commands
  >   # hold this box to. The pattern ends the command rather than merely
  >   # containing it: setup's own probe asks for {{.State}} and {{.Image}}
  >   # together, and an arm that matched both would answer the probe with a
  >   # version.
  >   *'name=^/bondi-orchestrator$'*"--format '{{.Image}}'") echo 'mlopez1506/bondi-server:0.20.0' ;;
  >   'docker exec -i bondi-orchestrator bondi-server deploy')
  >     cat > /dev/null
  >     echo 'the Bondi section of the crontab is malformed: an end marker closes a section that was never opened' >&2
  >     exit 1 ;;
  >   # Everything else. A command that falls through here answers nothing, and
  >   # nothing is a failure rather than an unstubbed command -- so what reaches
  >   # this arm was checked rather than left to chance. The deploy below reaches
  >   # it never. The setup reaches it with the alloy and managed listings, the
  >   # network ensure, the orchestrator's stop, removal and run, the alloy
  >   # directory removal, the orchestrator's own status subcommand and the two
  >   # listings the closing report reads. Every one of those is a command whose
  >   # empty answer is the answer this fixture wants: no alloy, no managed
  >   # container, a network and a recreate that succeed, and a closing report
  >   # this file asserts nothing about.
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"
  $ export SSH_ARGV_LOG="$ROOT/ssh-argv.log"

  $ cat > bondi.yaml <<'EOF'
  > cron_jobs:
  >   - name: nightly-report
  >     image: acme/report
  >     schedule: "0 3 * * *"
  >     server:
  >       ip_address: 127.0.0.1
  >       port: 9
  >       ssh:
  >         user: deploy
  >         private_key_contents: "not-a-real-key"
  >         private_key_pass: ""
  > bondi_server:
  >   version: "0.20.0"
  > EOF

The deploy is refused, and the message an operator reads is the box's, naming
which of the three malformations it is.

  $ bondi-client deploy nightly-report:v1 > deploy.log 2>&1
  [1]
  $ grep -c 'the Bondi section of the crontab is malformed: an end marker closes a section that was never opened' deploy.log
  1

The spool is byte-identical afterwards. A refusal that had already written half
a section would report as a refusal all the same, and every assertion that reads
only the exit code would still pass -- so the file is compared and not the
outcome.

  $ md5sum < "$SPOOL" > after.md5
  $ cmp before.md5 after.md5 && echo "the spool is unchanged"
  the spool is unchanged

The same spool, in front of setup. It proceeds, and its plan still carries the
copy of the cron payload directory out of the orchestrator -- which is the whole
of the divergence. Nothing about the crontab stops it, and nothing about it is
rewritten.

  $ : > ssh-argv.log
  $ bondi-client setup > setup.log 2>&1
  $ grep -c 'Preserved the cron payload directory on server 127.0.0.1' setup.log
  1

This configuration does declare a cron job, and the reading setup takes says so.
The crontab spool has to be writable for a box that schedules anything and is
beside the point for one that does not, and the container cannot tell which it
is on -- so the answer travels from bondi.yaml, in the command, and the box is
probed for exactly what it is meant to have.

  $ grep -c -- 'bondi-server check --cron-configured' ssh-argv.log
  1

And the spool is still byte-identical: proceeding is copying files, not writing
the section.

  $ md5sum < "$SPOOL" > after.md5
  $ cmp before.md5 after.md5 && echo "the spool is unchanged"
  the spool is unchanged
