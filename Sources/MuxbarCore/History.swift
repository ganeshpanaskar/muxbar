import Foundation

/// F9: search Claude Code and Codex conversation history on a host. The search runs there; only
/// hits (first prompt, a snippet around the match) and previews come back.
public enum AgentHistory {
    public static let maxPerHost = 50
    /// Seconds the host may spend searching.
    public static let timeLimit = 10

    public struct Hit: Equatable, Sendable, Identifiable {
        public var agent: AgentKind
        public var path: String
        public var id: String
        public var cwd: String?
        public var modified: Int
        public var messages: Int
        public var firstPrompt: String?
        public var before: String
        public var match: String
        public var after: String
        /// Who said the matching text: "user" or "assistant".
        public var role: String
        public var host: String = ""

        public init(agent: AgentKind, path: String, id: String, cwd: String? = nil, modified: Int = 0, messages: Int = 0,
                    firstPrompt: String? = nil, before: String = "", match: String = "", after: String = "", role: String = "",
                    host: String = "") {
            self.agent = agent; self.path = path; self.id = id; self.cwd = cwd; self.modified = modified; self.messages = messages
            self.firstPrompt = firstPrompt; self.before = before; self.match = match; self.after = after; self.role = role; self.host = host
        }

        public var title: String { (firstPrompt?.isEmpty == false ? firstPrompt! : "(no prompt)") }
        /// Unique across hosts (the same path can exist on two hosts).
        public var key: String { host + "|" + path }
    }

    public struct Turn: Equatable, Sendable {
        public var role: String      // user, assistant, tool
        public var text: String
    }

    public struct Preview: Equatable, Sendable {
        public var id: String?
        public var firstPrompt: String?
        public var turns: [Turn]
        public var cwd: String?
        public var gitBranch: String?
        public var model: String?
        public var bytes: Int?
    }

    /// One line, no control characters, at most 200 characters (it travels in an environment
    /// variable and is matched literally).
    public static func sanitizeQuery(_ q: String) -> String {
        let one = q.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : String($0) }.joined()
        return String(one.trimmingCharacters(in: .whitespaces).prefix(200))
    }

    /// The query as it appears inside a JSON string (what's in the transcript file).
    static func jsonEscaped(_ q: String) -> String {
        q.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    public static func defaultClaudeRoot() -> String { "$HOME/.claude/projects" }
    public static func defaultCodexRoot() -> String { "${CODEX_HOME:-$HOME/.codex}/sessions" }

    /// - Parameters:
    ///   - agent: nil = both.
    ///   - days: only files modified in the last N days (0 = all).
    ///   - claudeRoot/codexRoot: shell expressions (tests point them at fixtures).
    public static func searchScript(query: String, agent: AgentKind?, days: Int, limit: Int = maxPerHost,
                                    claudeRoot: String? = nil, codexRoot: String? = nil, nonce: String) -> String {
        let q = sanitizeQuery(query)
        let cr = claudeRoot.map(shellQuotePath) ?? "\"\(defaultClaudeRoot())\""
        let xr = codexRoot.map(shellQuotePath) ?? "\"\(defaultCodexRoot())\""
        // The query and roots reach perl only through the environment; the program is a constant.
        return """
        MUXBAR_Q=\(shellQuote(q)); MUXBAR_QJ=\(shellQuote(jsonEscaped(q)))
        MUXBAR_QL=\(shellQuote(jsonEscaped(q.lowercased()))); MUXBAR_QU=\(shellQuote(jsonEscaped(q.uppercased())))
        MBX_LIM=\(max(1, min(limit, maxPerHost))); MBX_M='@@\(nonce)'; MBX_DAYS=\(max(0, days)); MBX_TL=\(timeLimit - 1)
        MBX_AG=\(agent?.rawValue ?? "both"); MBX_CR=\(cr); MBX_XR=\(xr)
        export MUXBAR_Q MUXBAR_QJ MUXBAR_QL MUXBAR_QU MBX_LIM MBX_M MBX_DAYS MBX_TL MBX_AG MBX_CR MBX_XR
        P=$(cat <<'MBXPERL'
        \(perlProgram)
        MBXPERL
        )
        if [ -n "$MUXBAR_Q" ]; then
          if command -v timeout >/dev/null 2>&1; then timeout \(timeLimit + 2) perl -e "$P"; else perl -e 'alarm shift; exec @ARGV' \(timeLimit + 2) perl -e "$P"; fi
        fi
        echo "@@\(nonce) END"
        """
    }

    /// Lists transcripts newest first (days filter), scans each in 4 MB chunks for the query
    /// (ASCII case-insensitive; non-ASCII as typed, lower- or upper-case), and for files that
    /// contain it reads the details: id, cwd, message count, first prompt and a snippet of the
    /// first message whose text matches. Tool output and JSON keys don't count. Stops at MBX_LIM
    /// hits or the time limit (then prints PARTIAL scanned/total).
    static let perlProgram = #"""
    use strict; use warnings; use JSON::PP; use File::Find;
    binmode(STDOUT, ':encoding(UTF-8)');
    my $t0 = time; my $deadline = $t0 + ($ENV{MBX_TL} || 9);
    my $m = $ENV{MBX_M} // '@@'; my $lim = $ENV{MBX_LIM} || 50; my $days = $ENV{MBX_DAYS} || 0; my $ag = $ENV{MBX_AG} // 'both';
    my $qc = $ENV{MUXBAR_Q} // ''; utf8::decode($qc); $qc = lc $qc;
    my @pat; my %seen; for my $k (qw(MUXBAR_QJ MUXBAR_QL MUXBAR_QU)) { my $v = lc($ENV{$k} // ''); push @pat, $v if length $v && !$seen{$v}++; }
    my $plen = 0; for (@pat) { $plen = length $_ if length $_ > $plen; }
    my $qj = $ENV{MUXBAR_QJ} // ''; utf8::decode($qj); $qj = lc $qj; my $ascii = ($qj !~ /[^\x00-\x7f]/);
    my @files;
    for my $r ([claude => $ENV{MBX_CR}], [codex => $ENV{MBX_XR}]) {
      my ($a, $root) = @$r; next unless defined $root && -d $root; next if $ag ne 'both' && $ag ne $a;
      find({ no_chdir => 1, wanted => sub { return unless /\.jsonl$/ && -f $_; my $mt = (stat _)[9];
        return if $days > 0 && $mt < $t0 - $days * 86400; push @files, [$a, $File::Find::name, $mt]; } }, $root);
    }
    @files = sort { $b->[2] <=> $a->[2] } @files;
    my $js = JSON::PP->new->utf8->allow_nonref;
    sub contains { my $p = shift; open(my $fh, '<', $p) or return 0; local $/ = \4194304; my $tail = '';
      while (my $c = <$fh>) { my $s = lc($tail . $c); for my $q (@pat) { return 1 if index($s, $q) >= 0; }
        $tail = $plen > 1 ? substr($s, -($plen - 1)) : ''; return 0 if time > $deadline; } return 0; }
    sub has { my $line = shift; if ($ascii) { my $l = lc $line; for my $q (@pat) { return 1 if index($l, $q) >= 0 } return 0 }
      my $u = $line; utf8::decode($u); return index(lc $u, $qj) >= 0; }
    sub clean { my $s = shift // ''; $s =~ s/~\|~/~ |~/g; $s =~ s/\s+/ /g; $s =~ s/^ //; $s =~ s/ $//; return $s; }
    sub mid { my $s = shift // ''; $s =~ s/~\|~/~ |~/g; $s =~ s/\s+/ /g; return $s; }
    sub parts { my $c = shift; return $c unless ref $c eq 'ARRAY';
      return join ' ', map { $_->{text} // () } grep { ref $_ eq 'HASH' && ($_->{type} // '') =~ /^(text|input_text|output_text)$/ } @$c; }
    sub msg { my ($a, $o) = @_; return () unless ref $o eq 'HASH';
      if ($a eq 'claude') { my $t = $o->{type} // ''; return () unless $t eq 'user' || $t eq 'assistant'; return () if $o->{isMeta};
        my $c = ref $o->{message} eq 'HASH' ? $o->{message}{content} : undef; my $x = parts($c); return () unless defined $x && length $x; return ($t, $x); }
      my $p = ref $o->{payload} eq 'HASH' ? $o->{payload} : {}; my $t = $o->{type} // ''; my $pt = $p->{type} // '';
      return ('user', $p->{message} // '') if $t eq 'event_msg' && $pt eq 'user_message';
      return ('assistant', $p->{message} // '') if $t eq 'event_msg' && $pt eq 'agent_message';
      return (); }
    my ($hits, $scanned) = (0, 0);
    for my $e (@files) {
      last if $hits >= $lim || time > $deadline;
      my ($a, $p, $mt) = @$e; $scanned++;
      next unless contains($p);
      open(my $fh, '<', $p) or next;
      my ($first, $id, $cwd, $n, $role, $pre, $mat, $post) = ('', '', '', 0, '', '', '', '');
      my ($tries, $ln) = (0, 0);
      while (my $line = <$fh>) {
        last if ++$ln % 2000 == 0 && time > $deadline;
        if ($a eq 'claude') { next unless index($line, '"type":"user"') >= 0 || index($line, '"type":"assistant"') >= 0; } else {
          if (!$id && index($line, '"type":"session_meta"') >= 0) { my $o = eval { $js->decode($line) }; if ($o && ref $o->{payload} eq 'HASH') { $id = $o->{payload}{id} // ''; $cwd = $o->{payload}{cwd} // ''; } next; }
          next unless index($line, '"type":"event_msg"') >= 0 && $line =~ /"(user_message|agent_message)"/; }
        $n++;
        # Decoding is the slow part (JSON::PP): skip huge lines and tool results (never your words),
        # and give up on a file after 300 lines that mention the query only outside message text.
        my $tool = index($line, '"tool_result"') >= 0;
        my $want = ($first eq '' && !$tool && $line =~ /"(user|user_message)"/)
                || ($mat eq '' && !$tool && $tries < 300 && length($line) < 524288 && has($line))
                || ($a eq 'claude' && (!$id || !$cwd));
        next unless $want;
        $tries++ if $mat eq '' && $first ne '';
        my $o = eval { $js->decode($line) } or next;
        if ($a eq 'claude') { $id ||= $o->{sessionId} // ''; $cwd ||= $o->{cwd} // ''; }
        my ($r, $t) = msg($a, $o); next unless defined $t && length $t;
        $first = $t if $r eq 'user' && $first eq '' && $t !~ /^\s*</ && $t !~ /^Caveat:/;
        if ($mat eq '') { my $i = index(lc $t, $qc);
          if ($i >= 0) { $role = $r; my $s = $i > 60 ? $i - 60 : 0; my $e = $i + length $qc;
            $pre = ($s > 0 ? "\x{2026}" : '') . substr($t, $s, $i - $s); $mat = substr($t, $i, length $qc);
            $post = substr($t, $e, 80) . (length($t) > $e + 80 ? "\x{2026}" : ''); } }
      }
      close $fh;
      next if $mat eq '';
      if (!$id) { ($id) = $p =~ /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/; $id //= ''; }
      $hits++;
      print "$m HIT~|~$a~|~", clean($p), "~|~$mt~|~$n~|~", clean($id), "~|~", clean($cwd), "~|~", clean(substr($first, 0, 200)),
            "~|~", mid($pre), "~|~", mid($mat), "~|~", mid($post), "~|~$role\n";
    }
    print "$m PARTIAL $scanned/", scalar(@files), "\n" if $hits < $lim && $scanned < @files;
    """#

    /// "Searched the newest N of M conversations" when the time limit cut a search short.
    public static func parsePartial(_ out: String, nonce: String) -> (scanned: Int, total: Int)? {
        guard let line = out.split(separator: "\n").first(where: { $0.hasPrefix("@@\(nonce) PARTIAL ") }) else { return nil }
        let f = line.dropFirst("@@\(nonce) PARTIAL ".count).split(separator: "/")
        guard f.count == 2, let a = Int(f[0]), let b = Int(f[1]) else { return nil }
        return (a, b)
    }

    public static func parseHits(_ out: String, nonce: String, host: String = "") -> [Hit] {
        let m = "@@\(nonce) HIT" + HostProbe.fieldSep
        return out.split(separator: "\n").compactMap { raw -> Hit? in
            guard raw.hasPrefix(m) else { return nil }
            let f = HostProbe.fields(String(raw.dropFirst(m.count)), 11)
            guard f.count == 11, let agent = AgentKind(rawValue: f[0]), let mt = Int(f[2]) else { return nil }
            return Hit(agent: agent, path: f[1], id: f[4], cwd: f[5].isEmpty ? nil : f[5], modified: mt, messages: Int(f[3]) ?? 0,
                       firstPrompt: f[6].isEmpty ? nil : f[6], before: f[7], match: f[8], after: f[9], role: f[10], host: host)
        }
    }

    /// The start and end of a transcript (enough for the first prompt and the last turns).
    public static func previewScript(path: String, nonce: String) -> String {
        """
        F=\(shellQuotePath(path))
        [ -f "$F" ] || { echo "@@\(nonce) NOFILE"; exit 0; }
        echo "@@\(nonce) SIZE $(wc -c < "$F" | tr -d ' ')"
        echo "@@\(nonce) HEAD"; head -c 200000 "$F"; echo
        echo "@@\(nonce) TAIL"; tail -c 400000 "$F"; echo
        echo "@@\(nonce) END"
        """
    }

    public static func parsePreview(_ out: String, nonce: String, agent: AgentKind, turns limit: Int = 6) -> Preview? {
        var head: [Substring] = [], tail: [Substring] = [], cur = 0, size: Int?
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "@@\(nonce) NOFILE" { return nil }
            if line.hasPrefix("@@\(nonce) SIZE ") { size = Int(line.dropFirst("@@\(nonce) SIZE ".count)); continue }
            if line == "@@\(nonce) HEAD" { cur = 1; continue }
            if line == "@@\(nonce) TAIL" { cur = 2; continue }
            if line == "@@\(nonce) END" { cur = 0; continue }
            if cur == 1 { head.append(line) } else if cur == 2 { tail.append(line) }
        }
        var p = preview(head: head.joined(separator: "\n"), tail: tail.joined(separator: "\n"), agent: agent, turns: limit)
        p.bytes = size
        return p
    }

    /// First prompt, id, cwd and branch from the head; the last turns and model from the tail.
    public static func preview(head: String, tail: String, agent: AgentKind, turns limit: Int = 6) -> Preview {
        var p = Preview(id: nil, firstPrompt: AgentTranscript.firstUserText(head, agent: agent), turns: [])
        for raw in head.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { continue }
            switch agent {
            case .claude:
                p.id = p.id ?? o["sessionId"] as? String
                p.cwd = p.cwd ?? o["cwd"] as? String
                if let b = o["gitBranch"] as? String, !b.isEmpty { p.gitBranch = p.gitBranch ?? b }
            case .codex:
                if o["type"] as? String == "session_meta", let pl = o["payload"] as? [String: Any] {
                    p.id = pl["id"] as? String; p.cwd = pl["cwd"] as? String
                    if let g = pl["git"] as? [String: Any] { p.gitBranch = g["branch"] as? String }
                }
                if o["type"] as? String == "turn_context", let pl = o["payload"] as? [String: Any] { p.model = pl["model"] as? String ?? p.model }
            }
            if p.id != nil && p.cwd != nil && (agent == .codex || p.gitBranch != nil) { break }
        }
        var turns: [Turn] = []
        for raw in tail.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { continue }
            turns += self.turns(o, agent: agent, model: &p.model)
        }
        p.turns = Array(turns.suffix(limit))
        return p
    }

    static func turns(_ o: [String: Any], agent: AgentKind, model: inout String?) -> [Turn] {
        switch agent {
        case .claude:
            let type = o["type"] as? String
            if type == "user", let t = AgentTranscript.userText(o, agent: .claude) { return [Turn(role: "user", text: AgentTranscript.oneLine(t, limit: 400))] }
            guard type == "assistant", let m = o["message"] as? [String: Any] else { return [] }
            if let md = m["model"] as? String, !md.hasPrefix("<") { model = md }
            if let s = m["content"] as? String { return [Turn(role: "assistant", text: AgentTranscript.oneLine(s, limit: 400))] }
            var out: [Turn] = []
            for part in m["content"] as? [[String: Any]] ?? [] {
                if part["type"] as? String == "text", let t = part["text"] as? String, !t.isEmpty {
                    out.append(Turn(role: "assistant", text: AgentTranscript.oneLine(t, limit: 400)))
                } else if part["type"] as? String == "tool_use" {
                    out.append(Turn(role: "tool", text: toolSummary(part["name"] as? String ?? "tool", part["input"] as? [String: Any] ?? [:])))
                }
            }
            return out
        case .codex:
            let pl = o["payload"] as? [String: Any] ?? [:]
            if o["type"] as? String == "turn_context", let md = pl["model"] as? String { model = md }
            if o["type"] as? String == "event_msg" {
                if pl["type"] as? String == "user_message", let t = pl["message"] as? String { return [Turn(role: "user", text: AgentTranscript.oneLine(t, limit: 400))] }
                if pl["type"] as? String == "agent_message", let t = pl["message"] as? String { return [Turn(role: "assistant", text: AgentTranscript.oneLine(t, limit: 400))] }
            }
            if o["type"] as? String == "response_item", pl["type"] as? String == "function_call" {
                var input: [String: Any] = [:]
                if let a = pl["arguments"] as? String, let d = a.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { input = j }
                return [Turn(role: "tool", text: toolSummary(pl["name"] as? String ?? "tool", input))]
            }
            return []
        }
    }

    /// "⏺ Bash: npm test", "⏺ Edit: Sources/App.swift".
    static func toolSummary(_ name: String, _ input: [String: Any]) -> String {
        var arg = ""
        for k in ["command", "cmd", "file_path", "path", "pattern", "url", "description", "prompt"] {
            if let s = input[k] as? String, !s.isEmpty { arg = s; break }
            if let a = input[k] as? [String], !a.isEmpty { arg = a.joined(separator: " "); break }
        }
        return "⏺ \(name)" + (arg.isEmpty ? "" : ": " + AgentTranscript.oneLine(arg, limit: 120))
    }

    /// What "Copy resume command" puts on the clipboard.
    public static func resumeCommandLine(agent: AgentKind, id: String, cwd: String?) -> String {
        switch agent {
        case .claude:
            return (cwd.map { "cd \(shellQuotePath($0)) && " } ?? "") + AgentAdapter.resumeCommand(.claude, sessionID: id, cwd: cwd, flags: [])
        case .codex:
            return AgentAdapter.resumeCommand(.codex, sessionID: id, cwd: cwd, flags: [])
        }
    }
}
