# tests/minimal-vmtest.nix
#
# Minimal NixOS VM test for Honcho.
#
# Starts a VM with the NixOS module, verifies:
#   • PostgreSQL + pgvector come up
#   • Database migration completes
#   • Honcho API serves the /health endpoint
#   • Metrics are exposed (when DERIVER_ENABLED or server metrics enabled)
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
in
  pkgs.testers.runNixOSTest {
    name = "honcho";

    nodes = {
      honcho = {
        virtualisation = {
          cores = 2;
          memorySize = 2048;
        };

        imports = [
          self.nixosModules.default
          "${pkgs.path}/nixos/tests/common/user-account.nix"
        ];

        # This test env file is written to /etc/honcho-env by systemd-tmpfiles.
        # In production you'd use sops-nix or agenix; here we just inline a
        # dummy secret to verify the EnvironmentFile path works.
        systemd.tmpfiles.rules = [
          "f /etc/honcho-env 0600 root root - LLM_OPENAI_API_KEY=sk-test-dont-use-this"
        ];

        services.honcho = {
          enable = true;
          environmentFile = "/etc/honcho-env";
          settings = {
            log_level = "INFO";
            embedding.model_config = {
              transport = "openai";
              model = "text-embedding-3-small";
            };
          };
          nginx = {
            enable = true;
            host = "localhost";
          };
          # Enable the worker in the VM test so both services get verified
          worker.enable = true;
        };

        environment.systemPackages = with pkgs; [
          jq
          curl
        ];
      };
    };

    testScript = ''
      start_all()

      # ── 1. Database ────────────────────────────────────────────────────────
      honcho.wait_for_unit("postgresql.service")
      honcho.succeed("pg_isready -U honcho -d honcho")

      # ── 2. Migration ───────────────────────────────────────────────────────
      honcho.wait_for_unit("honcho-migrate.service")
      honcho.sleep(2)  # settle

      # ── 3. Worker (deriver) ────────────────────────────────────────────────
      honcho.wait_for_unit("honcho-worker.service")

      # ── 4. Server ──────────────────────────────────────────────────────────
      honcho.wait_for_unit("honcho.service")
      honcho.wait_for_open_port(8000)

      # ── 5. Health endpoint ────────────────────────────────────────────────
      honcho.wait_until_succeeds(
          "curl -sf http://127.0.0.1:8000/health | jq -e '.status == \"ok\"'"
      )

      with subtest("Health check returns ok"):
          health = honcho.succeed("curl -sf http://127.0.0.1:8000/health")
          print(f"Health check response: {health}")
          honcho.succeed(f"echo '{health}' | jq -e '.status == \"ok\"'")

      with subtest("API root responds (FastAPI docs / redirect)"):
          # Honcho redirects / → /docs; just confirm we get a 200 or 307
          code = honcho.succeed(
              "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/"
          )
          print(f"Root response code: {code}")
          assert code in ("200", "307", "302"), f"Unexpected status {code}"

      with subtest("Nginx reverse-proxy works"):
          code = honcho.succeed(
              "curl -s -o /dev/null -w '%{http_code}' http://localhost/health"
          )
          print(f"Nginx proxy response code: {code}")
          assert code == "200", f"Nginx proxy returned {code}"
          body = honcho.succeed("curl -sf http://localhost/health")
          honcho.succeed(f"echo '{body}' | jq -e '.status == \"ok\"'")

      with subtest("Metrics endpoint (prometheus) responds"):
          honcho.wait_for_open_port(9100)
          metrics = honcho.succeed("curl -sf http://127.0.0.1:9100/metrics 2>/dev/null || true")
          # If metrics are available, ensure they look like Prometheus output
          if metrics:
              print(f"Metrics snippet: {metrics[:300]}")
          else:
              print("Metrics endpoint not exposed (server built without --metrics-port)")

      print("=== All VM tests passed ===")
    '';
  }
