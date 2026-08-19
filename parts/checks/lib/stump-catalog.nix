# Shared Stump-catalog scaffolding for VM checks (ADR-0031).
#
# Two checks stand a real Stump up over the git-annex library tree and need the same three things
# from it: a real book to index, a way to ask the server what it has indexed, and a way to wait for
# the scanner. They were copy-pasted between them; this is the extraction, following the pattern
# `modules/nixos/services/git-annex/tests/lib.nix` already sets for shared test scaffolding.
#
# The consumers differ only in which node runs Stump and which account they query as, so those are
# parameters rather than two copies. `catalog()` returns the RICH shape (path, pattern, books) even
# for callers that only read the names — one shape to keep in step with Stump's schema, which is
# the part that will actually drift.
{ pkgs }:
let
  # A real PDF, not a stub. Stump dispatches on content type and only handles zip/rar/epub/pdf, so
  # a stub file never becomes a catalog entry and any read-path assertion over it is vacuous. groff
  # emits a valid PDF from a tiny troff source without dragging in a document toolchain.
  # `groff.perl` is required as well as `groff`: nixpkgs splits the perl-implemented drivers into
  # their own output, and `gropdf` — the one this needs — is among them, so plain `groff` fails
  # with "couldn't exec gropdf".
  book =
    name: text:
    pkgs.runCommand "${name}.pdf"
      {
        nativeBuildInputs = [
          pkgs.groff
          pkgs.groff.perl
        ];
      }
      ''
        printf '.SH\n%s\n.PP\n%s\n' ${pkgs.lib.escapeShellArg name} ${pkgs.lib.escapeShellArg text} \
          | groff -T pdf -ms > $out
      '';
in
{
  inherit book;

  # The same book, sized so that KOReader's hash sampler never reads a SHORT chunk — which is the
  # whole point of it. `util.partialMD5` samples 1 KiB at offsets 0, 1 KiB, 4 KiB, 16 KiB, 64 KiB …
  # and stops at the first offset past EOF; where the LAST sampled chunk straddles EOF, KOReader
  # hashes the bytes it got while Stump hashes a zero-padded 1 KiB buffer
  # (core/src/filesystem/hash.rs reads into a fixed vec and consumes all of it), and the two
  # disagree. Only file sizes that avoid a straddle let a test cross-check Stump's hash against
  # KOReader's algorithm rather than against a re-implementation of Stump's own.
  #
  # 4000 distinct tokens compress to roughly 12.7 KiB of PDF, which sits inside the safe band
  # [5 KiB, 16 KiB) with margin at both ends. The band is narrow, so the consumer ASSERTS the
  # no-short-chunk property rather than trusting this comment — if groff's output ever drifts out
  # of the band, the check says so instead of quietly comparing two implementations of the same
  # bug.
  bigBook =
    name: book name (pkgs.lib.concatStringsSep " " (pkgs.lib.genList (i: "w${toString i}") 4000));

  # Python helpers for a testScript: `graphql`, `catalog`, `wait_for_catalog`, `koreader_hash`.
  #
  # `node` is the test-driver machine running Stump; `owner`/`password` are the account the
  # provisioner claimed; `port` is the catalog port. Interpolated into the testScript at the top
  # level — the caller must also `import json`, `shlex` and `time`.
  #
  # The two imports below belong to `koreader_hash` and are carried HERE rather than left to the
  # caller: the test driver type-checks the assembled testScript, so a consumer that never calls
  # that helper would still fail to build with `Name 'base64' used when not defined`. Duplicating
  # an import a caller already has is free; making a shared helper depend on the caller's import
  # list is not.
  helpers =
    {
      node,
      owner,
      password,
      port,
    }:
    ''
      import base64
      import hashlib

      STUMP_LOCAL = "http://127.0.0.1:${toString port}"


      def graphql(query):
          """Run a query as the owner. The session cookie the REST login mints is what authorises
          the GraphQL endpoint, so both calls share one cookie jar."""
          ${node}.succeed(
              f"curl -sf -c /tmp/jar -X POST {STUMP_LOCAL}/api/v2/auth/login "
              "-H 'Content-Type: application/json' "
              f"""-d '{json.dumps({"username": "${owner}", "password": "${password}"})}' -o /dev/null"""
          )
          body = json.dumps({"query": query})
          raw = ${node}.succeed(
              f"curl -sf -b /tmp/jar -X POST {STUMP_LOCAL}/api/graphql "
              f"-H 'Content-Type: application/json' -d {shlex.quote(body)}"
          )
          parsed = json.loads(raw)
          assert "errors" not in parsed, f"GraphQL errors: {parsed}"
          return parsed["data"]


      def catalog():
          """{library name: {"path": ..., "pattern": ..., "books": [...]}} straight from the server."""
          data = graphql("{ libraries { nodes { name path config { libraryPattern } media { name } } } }")
          return {
              n["name"]: {
                  "path": n["path"],
                  "pattern": n["config"]["libraryPattern"],
                  "books": sorted(m["name"] for m in n["media"]),
              }
              for n in data["libraries"]["nodes"]
          }


      def koreader_hash(path):
          """KOReader's `util.partialMD5` (frontend/util.lua), computed in the test driver over
          bytes read out of the VM — an INDEPENDENT implementation of the algorithm, not a port of
          Stump's. That is the whole point: it is what makes "Stump's hash is the one the device
          will send" an assertion rather than a hope.

          1 KiB samples at offsets 0, 1 KiB, 4 KiB, 16 KiB … stopping at the first offset past
          EOF. The assertion on the chunk length is a FIXTURE GUARD, not a property of the
          algorithm: where the last sample straddles EOF the two implementations diverge (Stump
          zero-pads its buffer, KOReader does not), so a fixture in that regime would be comparing
          Stump against itself. `bigBook` exists to stay out of it."""
          raw = base64.b64decode(${node}.succeed(f"base64 -w0 {shlex.quote(path)}"))
          digest = hashlib.md5()
          for i in range(-1, 11):
              offset = 0 if i == -1 else 1024 << (2 * i)
              if offset >= len(raw):
                  break
              chunk = raw[offset:offset + 1024]
              assert len(chunk) == 1024, (
                  f"{path} is {len(raw)} bytes, so KOReader's sample at offset {offset} is short "
                  f"({len(chunk)} bytes) and Stump's zero-padded hash cannot be cross-checked "
                  "against it — resize the fixture (see bigBook in parts/checks/lib/stump-catalog.nix)"
              )
              digest.update(chunk)
          return digest.hexdigest()


      def wait_for_catalog(predicate, what, tries=60):
          """Poll the catalog until `predicate` holds. A scan is a background job kicked off by
          library creation (and by the watcher on a later drop), so `stump-provision` going active
          does not mean the books are indexed yet — without this the assertions race the scanner."""
          with ${node}.nested(f"waiting for the catalog: {what}"):
              for _ in range(tries):
                  snapshot = catalog()
                  if predicate(snapshot):
                      return snapshot
                  time.sleep(3)
          raise Exception(f"catalog never reached '{what}': {catalog()}")
    '';
}
