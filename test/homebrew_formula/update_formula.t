The release rewrites the tap's formula with the new version and the Linux
tarball's sha256. A rewrite that bumps the version but misses the sha256 ships
a formula whose checksum names the previous tarball, and that formula installs
nothing. So the updater rewrites only a formula it can read without guessing:
one version, one url and one sha256 line (commented-out lines count too, so a
leftover block is refused rather than tolerated), the url naming the Linux
tarball, its sha256 on the very next line. Anything else exits 1, says what
failed, and leaves the file byte-identical.

Dune's copies of the inputs are read-only, so each working copy is made
writable first. Otherwise "unchanged" would hold because the updater could not
write, not because it refused to.

  $ ROOT="$PWD"
  $ UPDATE="$ROOT/../../.github/actions/update-homebrew-formula/update_formula.py"
  $ SHA=abababababababababababababababababababababababababababababababab
  $ refused() {
  >   cp -f "fixtures/$1" work.rb && chmod u+w work.rb
  >   python3 "$UPDATE" work.rb 0.26.0 "$SHA"
  >   echo "exit $?"
  >   cmp "fixtures/$1" work.rb && echo "byte-identical"
  > }

The formula this repository ships: the version and the sha256 each change, and
nothing else does.

  $ cp -f ../../packaging/homebrew/bondi.rb packaging.rb && chmod u+w packaging.rb
  $ python3 "$UPDATE" packaging.rb 0.26.0 "$SHA"
  $ diff -u --label before --label after ../../packaging/homebrew/bondi.rb packaging.rb
  --- before
  +++ after
  @@ -4,13 +4,13 @@
   class Bondi < Formula
       desc "Bondi CLI - deployment and orchestration tool"
       homepage "https://github.com/puravida-software/bondi"
  -    version "0.0.0"
  +    version "0.26.0"
       license "MIT"
   
       on_linux do
         on_intel do
           url "https://github.com/puravida-software/bondi/releases/download/v#{version}/bondi-linux-x86_64.tar.gz"
  -        sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  +        sha256 "abababababababababababababababababababababababababababababababab"
         end
       end
   
  [1]

The tap's formula, laid out as it is once its macOS block is removed: a
top-level version with a trailing comment, and the url/sha256 pair directly
inside on_linux. [observed — 2026-11-16: read from the tap's Formula/bondi.rb,
macOS block removed by hand; everything else as read.]

  $ cp -f fixtures/tap.rb tap.rb && chmod u+w tap.rb
  $ python3 "$UPDATE" tap.rb 0.26.0 "$SHA"
  $ diff -u --label before --label after fixtures/tap.rb tap.rb
  --- before
  +++ after
  @@ -1,11 +1,11 @@
   class Bondi < Formula
     desc "Bondi CLI"
     homepage "https://github.com/puravida-software/bondi"
  -  version "0.25.0" # update on release
  +  version "0.26.0" # update on release
   
     on_linux do
       url "https://github.com/puravida-software/bondi/releases/download/v#{version}/bondi-linux-x86_64.tar.gz"
  -    sha256 "9175689fea6c734e057a3cc1ef592d92e9dc35b9e8072feeb1e06f04a50504e4"
  +    sha256 "abababababababababababababababababababababababababababababababab"
     end
   
     def install
  [1]

A comment between the url and its sha256. A substitution that expects them on
adjacent lines matches nothing here and, unchecked, still bumps the version.
This formula also keeps a commented-out macOS pair, which counts.

  $ refused line_between_url_and_sha256.rb
  ::error::url lines (commented-out ones included): 2; expected exactly one
  ::error::sha256 lines (commented-out ones included): 2; expected exactly one
  ::error::the line after the bondi-linux-x86_64.tar.gz url is not its sha256 line
  ::error::work.rb left unchanged
  exit 1
  byte-identical

A second sha256 line, live.

  $ refused second_sha256.rb
  ::error::sha256 lines (commented-out ones included): 2; expected exactly one
  ::error::work.rb left unchanged
  exit 1
  byte-identical

A second url line, naming another tarball.

  $ refused second_url.rb
  ::error::url lines (commented-out ones included): 2; expected exactly one
  ::error::work.rb left unchanged
  exit 1
  byte-identical

The tap as it was read, still carrying its macOS pair. The release refuses it
until that block is removed from the tap, and the tap keeps its previous
formula meanwhile. [observed — 2026-11-16: the tap's Formula/bondi.rb, as
read.]

  $ refused tap_with_macos.rb
  ::error::url lines (commented-out ones included): 2; expected exactly one
  ::error::sha256 lines (commented-out ones included): 2; expected exactly one
  ::error::work.rb left unchanged
  exit 1
  byte-identical

A commented-out sha256 left beside the live one.

  $ refused leftover_commented_sha256.rb
  ::error::sha256 lines (commented-out ones included): 2; expected exactly one
  ::error::work.rb left unchanged
  exit 1
  byte-identical

The pair's only sha256 commented out. The counts hold and the lines are
adjacent, but rewriting a comment would ship a formula with no checksum.

  $ refused pair_sha256_commented_out.rb
  ::error::the bondi-linux-x86_64.tar.gz url or its sha256 line is commented out
  ::error::work.rb left unchanged
  exit 1
  byte-identical

A second version line.

  $ refused second_version.rb
  ::error::version "..." appears 2 times; expected exactly once
  ::error::work.rb left unchanged
  exit 1
  byte-identical

One pair, naming a tarball the release does not build.

  $ refused url_not_linux.rb
  ::error::no url line names bondi-linux-x86_64.tar.gz
  ::error::work.rb left unchanged
  exit 1
  byte-identical

The pair's url commented out while its sha256 stays live: the other half of the
commented-pair refusal.

  $ refused pair_url_commented_out.rb
  ::error::the bondi-linux-x86_64.tar.gz url or its sha256 line is commented out
  ::error::work.rb left unchanged
  exit 1
  byte-identical

The only version line commented out. Rewriting inside the comment would leave
the formula with no version at all.

  $ refused commented_version.rb
  ::error::the version "..." line is commented out
  ::error::work.rb left unchanged
  exit 1
  byte-identical

An empty version.

  $ cp -f fixtures/tap.rb work.rb && chmod u+w work.rb
  $ python3 "$UPDATE" work.rb "" "$SHA"
  ::error::version must not be empty
  ::error::work.rb left unchanged
  [1]
  $ cmp fixtures/tap.rb work.rb && echo "byte-identical"
  byte-identical

A checksum that is empty (a tarball that was not found) or not 64 lowercase hex
digits is refused, and so is every other failure alongside it.

  $ python3 "$UPDATE" work.rb 0.26.0 ""
  ::error::LINUX_SHA must be 64 lowercase hex digits, got ''
  ::error::work.rb left unchanged
  [1]
  $ python3 "$UPDATE" work.rb 0.26.0 "abab"
  ::error::LINUX_SHA must be 64 lowercase hex digits, got 'abab'
  ::error::work.rb left unchanged
  [1]
  $ python3 "$UPDATE" work.rb 0.26.0 "$(printf '%s\n%s' "$SHA" "$SHA")"
  ::error::LINUX_SHA must be 64 lowercase hex digits, got 'abababababababababababababababababababababababababababababababab\nabababababababababababababababababababababababababababababababab'
  ::error::work.rb left unchanged
  [1]
  $ cp -f fixtures/second_version.rb work2.rb && chmod u+w work2.rb
  $ python3 "$UPDATE" work2.rb "" "abab"
  ::error::version must not be empty
  ::error::LINUX_SHA must be 64 lowercase hex digits, got 'abab'
  ::error::version "..." appears 2 times; expected exactly once
  ::error::work2.rb left unchanged
  [1]
  $ cmp fixtures/tap.rb work.rb && echo "byte-identical"
  byte-identical

The wrong number of arguments prints a usage line, not a traceback, and touches
nothing.

  $ python3 "$UPDATE" work.rb 0.26.0
  usage: update_formula.py FORMULA VERSION LINUX_SHA
  [1]
  $ python3 "$UPDATE" work.rb 0.26.0 "$SHA" extra
  usage: update_formula.py FORMULA VERSION LINUX_SHA
  [1]
  $ cmp fixtures/tap.rb work.rb && echo "byte-identical"
  byte-identical

Line endings are kept exactly: a CRLF formula comes back with every line still
ending in CRLF, and the version and sha256 rewritten.

  $ cp -f fixtures/tap_crlf.rb crlf.rb && chmod u+w crlf.rb
  $ python3 "$UPDATE" crlf.rb 0.26.0 "$SHA"
  $ grep -c "$(printf '\r')\$" crlf.rb; wc -l < crlf.rb
  14
  14
  $ grep -c -e 'version "0.26.0"' -e "$SHA" crlf.rb
  2
