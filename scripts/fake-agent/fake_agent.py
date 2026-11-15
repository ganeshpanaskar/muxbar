#!/usr/bin/python3
"""Stand-in for Claude Code or Codex in Muxbar's tests (no model, no network, no tokens).

It acts as `claude` or `codex` (from --as or the name it was started under). It draws a minimal
screen in that agent's style and fires the same hook events the real agent would, by running the
real hook script ($MUXBAR_FAKE_HOOK) with payloads in that agent's format. It also writes a small
transcript (under $MUXBAR_FAKE_TRANSCRIPTS) and resumes by id, keeping the flags it was given.

Commands typed at its prompt:
  work N [text]   busy for N seconds (spinner, tool events), then finish with a reply
  reply TEXT      like `work 1 TEXT`
  ask             ask for permission to run a command; answer 1 (yes) or 2 (no)
  question        (claude) multiple-choice question; answer with a number
  silent N        start a turn, then go quiet at the prompt without finishing (no Stop event)
  bg              start a background child process (`sleep 600`)
  quit | /exit    end the session
  anything else   treated as a prompt: a 1-second turn that replies "ok: <text>"
Ctrl-C during a turn interrupts it (codex fires Interrupt). Ctrl-C twice at the prompt exits.
"""
import datetime
import json
import os
import re
import subprocess
import sys
import time
import uuid

argv = sys.argv[1:]
agent = os.path.basename(sys.argv[0])
if "--as" in argv:
    i = argv.index("--as")
    agent = argv[i + 1]
    del argv[i:i + 2]
agent = "codex" if agent.startswith("codex") else "claude"

if argv[:1] in (["--version"], ["-v"]):
    print("fake %s 0.0.0 (muxbar-e2e)" % agent)
    sys.exit(0)

sid = None
resumed = False
flags = []
rest = list(argv)
if agent == "claude":
    while rest:
        a = rest.pop(0)
        if a in ("--resume", "-r") and rest:
            sid, resumed = rest.pop(0), True
        elif a in ("--continue", "-c"):
            resumed = True
        else:
            flags.append(a)
else:
    if rest[:1] == ["resume"]:
        rest.pop(0)
        resumed = True
        if rest and not rest[0].startswith("-"):
            sid = rest.pop(0)
    flags = rest
sid = sid or str(uuid.uuid4())
cwd = os.getcwd()
HOOK = os.environ.get("MUXBAR_FAKE_HOOK", "")
ROOT = os.environ.get("MUXBAR_FAKE_TRANSCRIPTS", "")


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def transcript_path():
    if not ROOT:
        return None
    if agent == "claude":
        return os.path.join(ROOT, "claude", re.sub(r"[^A-Za-z0-9]", "-", cwd), sid + ".jsonl")
    d = datetime.datetime.now()
    return os.path.join(ROOT, "codex", d.strftime("%Y/%m/%d"),
                        "rollout-%s-%s.jsonl" % (d.strftime("%Y-%m-%dT%H-%M-%S"), sid))


TPATH = transcript_path()
if TPATH and agent == "codex" and resumed:
    # Keep appending to the same rollout when resuming.
    base = os.path.join(ROOT, "codex")
    for dirpath, _, files in os.walk(base):
        for f in files:
            if f.endswith(sid + ".jsonl"):
                TPATH = os.path.join(dirpath, f)


def record(kind, text):
    if not TPATH:
        return
    os.makedirs(os.path.dirname(TPATH), exist_ok=True)
    fresh = not os.path.exists(TPATH)
    with open(TPATH, "a") as f:
        if agent == "claude":
            if kind == "user":
                line = {"type": "user", "message": {"role": "user", "content": text}}
            else:
                line = {"type": "assistant", "message": {"role": "assistant", "model": "fake",
                                                         "content": [{"type": "text", "text": text}]}}
            line.update({"sessionId": sid, "cwd": cwd, "gitBranch": "", "timestamp": now_iso(),
                         "uuid": str(uuid.uuid4())})
        else:
            if fresh:
                f.write(json.dumps({"timestamp": now_iso(), "type": "session_meta",
                                    "payload": {"id": sid, "cwd": cwd, "originator": "codex_cli_rs",
                                                "cli_version": "fake"}}) + "\n")
            part = {"type": "input_text" if kind == "user" else "output_text", "text": text}
            line = {"timestamp": now_iso(), "type": "response_item",
                    "payload": {"type": "message", "role": "user" if kind == "user" else "assistant",
                                "content": [part]}}
        f.write(json.dumps(line) + "\n")


turn = [0]


def emit(event, **extra):
    if not HOOK or not os.path.exists(HOOK):
        return
    p = {"session_id": sid, "transcript_path": TPATH, "cwd": cwd, "hook_event_name": event}
    if agent == "codex":
        p.update({"model": "gpt-fake", "permission_mode": "default"})
        if event not in ("SessionStart", "SessionEnd", "PreCompact", "PostCompact"):
            p["turn_id"] = "turn_%d" % turn[0]
    p.update(extra)
    try:
        subprocess.run([HOOK, agent, event], input=json.dumps(p).encode(), timeout=5,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def out(s=""):
    sys.stdout.write(s + "\n")
    sys.stdout.flush()


def prompt_box():
    if agent == "claude":
        out("─" * 60)
        sys.stdout.write("❯ ")
    else:
        out("")
        sys.stdout.write("› ")
    sys.stdout.flush()


def banner():
    if agent == "claude":
        out("╭" + "─" * 46 + "╮")
        out("│ ✻ Fake Claude Code (muxbar-e2e stand-in)     │")
        out("│   cwd: %-37s │" % cwd[-37:])
        out("╰" + "─" * 46 + "╯")
        out("  ? for shortcuts")
    else:
        out(">_ Fake Codex (muxbar-e2e stand-in)")
        out("   directory: %s" % cwd)
    if resumed:
        out("resumed %s" % sid)
    out("flags: %s" % " ".join(flags))


def spinner(seconds, what="Working"):
    """Busy display. Returns False if interrupted (Ctrl-C)."""
    start = time.time()
    try:
        while time.time() - start < seconds:
            el = int(time.time() - start)
            # Redrawn in place and cleared afterwards, like the real agents' status line.
            if agent == "claude":
                sys.stdout.write("\r\x1b[2K✻ %s… (%ds · esc to interrupt)" % (what, el))
            else:
                sys.stdout.write("\r\x1b[2K• %s (%ds • esc to interrupt)" % (what, el))
            sys.stdout.flush()
            time.sleep(1)
        return True
    except KeyboardInterrupt:
        return False
    finally:
        sys.stdout.write("\r\x1b[2K")
        sys.stdout.flush()


def finish(reply):
    out("⏺ " + reply if agent == "claude" else "codex: " + reply)
    record("assistant", reply)
    if agent == "claude":
        out("✻ Baked for 1s")
        emit("Stop", stop_hook_active=False)
    else:
        emit("Stop", stop_hook_active=False, last_assistant_message=reply)


def interrupted():
    out("Interrupted by user")
    if agent == "codex":
        emit("Interrupt")


def start_turn(text):
    turn[0] += 1
    out("❯ " + text if agent == "claude" else "› " + text)
    record("user", text)
    emit("UserPromptSubmit", prompt=text)


def tool(name, inp):
    emit("PreToolUse", tool_name=name, tool_input=inp, tool_use_id="tool_%d" % turn[0])


def tool_done(name, inp):
    emit("PostToolUse", tool_name=name, tool_input=inp, tool_use_id="tool_%d" % turn[0],
         tool_response={"ok": True})


def read_line():
    return sys.stdin.readline()


def erase(lines):
    """Removes the last `lines` lines from the screen (an answered dialog)."""
    sys.stdout.write("\x1b[%dA\r\x1b[J" % lines)
    sys.stdout.flush()


def handle(line):
    words = line.split()
    cmd = words[0] if words else ""
    if cmd in ("quit", "/exit", "/quit"):
        emit("SessionEnd", reason="other")
        sys.exit(0)
    if cmd == "bg":
        # Like a real agent's tool call: a shell that runs the job (`; :` keeps the shell from exec-ing
        # it). Own session, so Ctrl-C at the prompt doesn't kill it; still under us.
        p = subprocess.Popen(["/bin/sh", "-c", "sleep 600; :"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
        out("started background job %d" % p.pid)
        return
    if cmd == "ask":
        start_turn("run date")
        inp = {"command": "date", "description": "Print the date"}
        tool("Bash", inp)
        if agent == "claude":
            emit("Notification", message="Claude needs your permission to use Bash",
                 notification_type="permission_prompt")
        else:
            emit("PermissionRequest", tool_name="Bash", tool_input=inp)
        out("Bash command")
        out("  date")
        out(" Do you want to proceed?")
        out(" ❯ 1. Yes")
        out("   2. No")
        sys.stdout.write("> ")
        sys.stdout.flush()
        try:
            ans = read_line().strip().lower()
        except KeyboardInterrupt:
            interrupted()
            return
        erase(6)
        if ans in ("1", "y", "yes"):
            tool_done("Bash", inp)
            if spinner(1):
                finish("ran date")
            else:
                interrupted()
        else:
            finish("not run")
        return
    if cmd == "question" and agent == "claude":
        start_turn("pick one")
        tool("AskUserQuestion", {"questions": [{"question": "Pick one"}]})
        out(" Pick one")
        out(" ❯ 1. Apple")
        out("   2. Pear")
        sys.stdout.write("> ")
        sys.stdout.flush()
        try:
            ans = read_line().strip()
        except KeyboardInterrupt:
            interrupted()
            return
        erase(4)
        tool_done("AskUserQuestion", {"answer": ans})
        finish("picked %s" % ans)
        return
    if cmd == "silent":
        n = int(words[1]) if len(words) > 1 else 1
        start_turn("silent %d" % n)
        spinner(n)
        return  # back at the prompt without a Stop event (like an Esc interrupt in Claude)
    if cmd in ("work", "reply") or cmd:
        if cmd == "work":
            n = int(words[1]) if len(words) > 1 and words[1].isdigit() else 2
            text = " ".join(words[2:]) or "done %d" % n
            prompt_text = line.strip()
        elif cmd == "reply":
            n, text, prompt_text = 1, " ".join(words[1:]) or "ok", line.strip()
        else:
            n, text, prompt_text = 1, "ok: " + line.strip(), line.strip()
        start_turn(prompt_text)
        inp = {"command": "true"}
        tool("Bash", inp)
        ok = spinner(max(1, n // 2))
        if ok:
            tool_done("Bash", inp)
            ok = spinner(n - max(1, n // 2))
        if ok:
            finish(text)
        else:
            interrupted()


def main():
    emit("SessionStart", source="resume" if resumed else "startup")
    banner()
    last_ctrl_c = 0.0
    while True:
        prompt_box()
        try:
            line = read_line()
            if line == "":
                emit("SessionEnd", reason="other")
                return
            last_ctrl_c = 0.0
            handle(line)
        except KeyboardInterrupt:
            if time.time() - last_ctrl_c < 3:
                out("")
                emit("SessionEnd", reason="other")
                return
            last_ctrl_c = time.time()
            out("")
            out("Press Ctrl-C again to exit")


if __name__ == "__main__":
    main()
