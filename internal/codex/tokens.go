package codex

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// TokenUsageReport aggregates persisted token_count increments by their UTC event date.
// Cached input is a subset of input; reasoning is already included in output.
type TokenUsageReport struct {
	Source             string            `json:"source"`
	InputTokens        int64             `json:"input_tokens"`
	CachedInputTokens  int64             `json:"cached_input_tokens"`
	OutputTokens       int64             `json:"output_tokens"`
	UnavailableThreads int               `json:"unavailable_threads"`
	IncompleteFiles    int               `json:"incomplete_files"`
	FetchedAt          string            `json:"fetched_at"`
	TotalTokens        int64             `json:"total_tokens"`
	MaxDaily           int64             `json:"max_daily_tokens"`
	ActiveDays         int               `json:"active_days"`
	CurrentStreak      int               `json:"current_streak"`
	LongestStreak      int               `json:"longest_streak"`
	ThreadCount        int64             `json:"thread_count"`
	Daily              []DailyTokenUsage `json:"daily"`
}

type DailyTokenUsage struct {
	Date    string `json:"date"`
	Tokens  int64  `json:"tokens"`
	Threads int64  `json:"threads"`
}

const tokenReadTimeout = 90 * time.Second

// ReadTokenUsage discovers threads through read-only indexes and reads only
// rollout JSONL token events under the supplied homes' session directories.
func ReadTokenUsage(homes []string) (TokenUsageReport, error) {
	paths, err := tokenDatabasePaths(homes)
	if err != nil {
		return TokenUsageReport{}, err
	}
	report := TokenUsageReport{Source: "session_events", FetchedAt: time.Now().UTC().Format(time.RFC3339), Daily: []DailyTokenUsage{}}
	if len(paths) == 0 {
		return report, nil
	}
	python, err := findPython3()
	if err != nil {
		return report, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), tokenReadTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, python, "-c", tokenReaderScript)
	cmd.Args = append(cmd.Args, paths...)
	cmd.Env = os.Environ()
	data, err := cmd.Output()
	if err != nil {
		if ctx.Err() != nil {
			return report, errors.New("读取 Codex Token 记录超时")
		}
		var detail string
		if exitErr := new(exec.ExitError); errors.As(err, &exitErr) {
			detail = strings.TrimSpace(string(exitErr.Stderr))
		}
		if detail == "" {
			detail = err.Error()
		}
		return report, fmt.Errorf("读取 Codex Token 记录失败: %s", detail)
	}
	if err := json.Unmarshal(data, &report); err != nil {
		return TokenUsageReport{}, fmt.Errorf("解析 Codex Token 记录失败: %w", err)
	}
	if report.Daily == nil {
		report.Daily = []DailyTokenUsage{}
	}
	return report, nil
}

func tokenDatabasePaths(homes []string) ([]string, error) {
	seen := make(map[string]struct{}, len(homes))
	paths := make([]string, 0, len(homes))
	for _, home := range homes {
		home = strings.TrimSpace(home)
		if home == "" {
			continue
		}
		path, err := filepath.Abs(filepath.Join(home, "state_5.sqlite"))
		if err != nil {
			return nil, err
		}
		path = filepath.Clean(path)
		info, err := os.Lstat(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("inspect Codex Token database %s: %w", path, err)
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return nil, fmt.Errorf("拒绝读取非普通 Codex Token 数据库: %s", path)
		}
		if _, ok := seen[path]; ok {
			continue
		}
		seen[path] = struct{}{}
		paths = append(paths, path)
	}
	sort.Strings(paths)
	return paths, nil
}

func findPython3() (string, error) {
	for _, candidate := range []string{"/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"} {
		if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0 {
			return candidate, nil
		}
	}
	if candidate, err := exec.LookPath("python3"); err == nil {
		return candidate, nil
	}
	return "", errors.New("找不到 python3，无法读取 Codex Token 记录")
}

//go:embed token_reader.py
var tokenReaderScript string
