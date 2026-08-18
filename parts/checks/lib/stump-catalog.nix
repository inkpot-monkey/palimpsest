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
{
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

  # Python helpers for a testScript: `graphql`, `catalog`, `wait_for_catalog`.
  #
  # `node` is the test-driver machine running Stump; `owner`/`password` are the account the
  # provisioner claimed; `port` is the catalog port. Interpolated into the testScript at the top
  # level — the caller must also `import json`, `shlex` and `time`.
  helpers =
    {
      node,
      owner,
      password,
      port,
    }:
    ''
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
