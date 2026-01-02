#!/usr/bin/env python3
import os
import shlex
import subprocess
from avocado import Test


class AVLScript(Test):
    def test(self):
        rel_script = os.environ.get("AVL_SCRIPT", "").strip()
        args = os.environ.get("AVL_ARGS", "")

        if not rel_script:
            self.fail("Missing AVL_SCRIPT. Use: ./avlrun <script> [args...]")

        repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

        script_path = rel_script if os.path.isabs(rel_script) else os.path.join(repo_root, rel_script)
        script_path = os.path.abspath(script_path)

        if not os.path.exists(script_path):
            self.fail(f"Script not found: {script_path}")
        if not os.access(script_path, os.X_OK):
            self.fail(f"Script is not executable: {script_path} (try: chmod +x {rel_script})")

        argv = [script_path] + (shlex.split(args) if args else [])
        self.log.info("Running: %s", " ".join(shlex.quote(a) for a in argv))

        # Stream output live and detect "[ERR]" (with or without ANSI colors)
        saw_err = False

        env = os.environ.copy()
        proc = subprocess.Popen(
            argv,
            cwd=repo_root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            universal_newlines=True,
        )

        assert proc.stdout is not None
        for line in proc.stdout:
            line = line.rstrip("\n")
            self.log.info("%s", line)
            # Detect plain "[ERR]" or ANSI-colored variants that still include "[ERR]"
            if "[ERR]" in line:
                saw_err = True

        rc = proc.wait()

        # Option B policy:
        # - FAIL only if output contained "[ERR]"
        # - Otherwise PASS even if rc != 0
        if saw_err:
            self.fail(f"Script reported [ERR] (exit status: {rc})")
        else:
            # Keep visibility of non-zero exit without failing the test
            if rc != 0:
                self.log.warning("Script exited non-zero (%d) but no [ERR] seen; treating as PASS", rc)

