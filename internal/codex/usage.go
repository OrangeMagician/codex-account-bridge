package codex

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

const usageReadTimeout = 20 * time.Second
const usageReadAttempts = 3
const usageReadRetryDelay = 350 * time.Millisecond
const usageProbeTimeout = 45 * time.Second
const usageResetTimeout = 20 * time.Second

const DefaultUsageProbeModel = "gpt-5.6-luna"

type synchronizedBuffer struct {
	mu      sync.Mutex
	builder strings.Builder
}

func (b *synchronizedBuffer) Write(data []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.builder.Write(data)
}

func (b *synchronizedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.builder.String()
}

type UsageSnapshot struct {
	PlanType            string                       `json:"plan_type,omitempty"`
	RateLimits          RateLimitSnapshot            `json:"rate_limits"`
	RateLimitsByLimitID map[string]RateLimitSnapshot `json:"rate_limits_by_limit_id,omitempty"`
	ResetCredits        *ResetCreditsSummary         `json:"reset_credits,omitempty"`
}

type RateLimitSnapshot struct {
	LimitID              string                     `json:"limit_id,omitempty"`
	LimitName            string                     `json:"limit_name,omitempty"`
	Primary              *RateLimitWindow           `json:"primary,omitempty"`
	Secondary            *RateLimitWindow           `json:"secondary,omitempty"`
	Credits              *CreditsSnapshot           `json:"credits,omitempty"`
	IndividualLimit      *SpendControlLimitSnapshot `json:"individual_limit,omitempty"`
	SpendControlReached  *bool                      `json:"spend_control_reached,omitempty"`
	PlanType             string                     `json:"plan_type,omitempty"`
	RateLimitReachedType string                     `json:"rate_limit_reached_type,omitempty"`
}

type RateLimitWindow struct {
	UsedPercent        float64 `json:"used_percent"`
	WindowDurationMins *int64  `json:"window_duration_mins,omitempty"`
	ResetsAt           *int64  `json:"resets_at,omitempty"`
}

type CreditsSnapshot struct {
	HasCredits bool   `json:"has_credits"`
	Unlimited  bool   `json:"unlimited"`
	Balance    string `json:"balance,omitempty"`
}

type SpendControlLimitSnapshot struct {
	Limit            string  `json:"limit"`
	Used             string  `json:"used"`
	RemainingPercent float64 `json:"remaining_percent"`
	ResetsAt         int64   `json:"resets_at"`
}

type ResetCreditsSummary struct {
	AvailableCount int64             `json:"available_count"`
	Credits        []RateLimitCredit `json:"credits,omitempty"`
}

type RateLimitCredit struct {
	ID          string `json:"id"`
	ResetType   string `json:"reset_type,omitempty"`
	Status      string `json:"status,omitempty"`
	GrantedAt   int64  `json:"granted_at"`
	ExpiresAt   *int64 `json:"expires_at,omitempty"`
	Title       string `json:"title,omitempty"`
	Description string `json:"description,omitempty"`
}

type rpcAccountRead struct {
	Account *struct {
		Type     string `json:"type"`
		PlanType string `json:"planType"`
	} `json:"account"`
}

type rpcRateLimitResponse struct {
	RateLimits          rpcRateLimitSnapshot            `json:"rateLimits"`
	RateLimitsByLimitID map[string]rpcRateLimitSnapshot `json:"rateLimitsByLimitId"`
	ResetCredits        *rpcResetCreditsSummary         `json:"rateLimitResetCredits"`
}

type rpcRateLimitSnapshot struct {
	LimitID              *string                       `json:"limitId"`
	LimitName            *string                       `json:"limitName"`
	Primary              *rpcRateLimitWindow           `json:"primary"`
	Secondary            *rpcRateLimitWindow           `json:"secondary"`
	Credits              *rpcCreditsSnapshot           `json:"credits"`
	IndividualLimit      *rpcSpendControlLimitSnapshot `json:"individualLimit"`
	SpendControlReached  *bool                         `json:"spendControlReached"`
	PlanType             *string                       `json:"planType"`
	RateLimitReachedType *string                       `json:"rateLimitReachedType"`
}

type rpcRateLimitWindow struct {
	UsedPercent        float64 `json:"usedPercent"`
	WindowDurationMins *int64  `json:"windowDurationMins"`
	ResetsAt           *int64  `json:"resetsAt"`
}

type rpcCreditsSnapshot struct {
	HasCredits bool    `json:"hasCredits"`
	Unlimited  bool    `json:"unlimited"`
	Balance    *string `json:"balance"`
}

type rpcSpendControlLimitSnapshot struct {
	Limit            string  `json:"limit"`
	Used             string  `json:"used"`
	RemainingPercent float64 `json:"remainingPercent"`
	ResetsAt         int64   `json:"resetsAt"`
}

type rpcResetCreditsSummary struct {
	AvailableCount int64                `json:"availableCount"`
	Credits        []rpcRateLimitCredit `json:"credits"`
}

type rpcRateLimitCredit struct {
	ID          string  `json:"id"`
	ResetType   string  `json:"resetType"`
	Status      string  `json:"status"`
	GrantedAt   int64   `json:"grantedAt"`
	ExpiresAt   *int64  `json:"expiresAt"`
	Title       *string `json:"title"`
	Description *string `json:"description"`
}

type UsageResetOutcome string

const (
	UsageResetCompleted       UsageResetOutcome = "reset"
	UsageResetNothingToReset  UsageResetOutcome = "nothingToReset"
	UsageResetNoCredit        UsageResetOutcome = "noCredit"
	UsageResetAlreadyRedeemed UsageResetOutcome = "alreadyRedeemed"
)

type rpcUsageResetResponse struct {
	Outcome UsageResetOutcome `json:"outcome"`
}

// ReadUsage asks the official Codex app-server for the selected ChatGPT
// account's plan and rate-limit snapshot. It never reads auth storage itself.
func ReadUsage(home string) (UsageSnapshot, error) {
	binary, err := FindReal("codex")
	if err != nil {
		return UsageSnapshot{}, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), usageReadTimeout)
	defer cancel()

	var lastErr error
	for attempt := 1; attempt <= usageReadAttempts; attempt++ {
		usage, err := readUsageOnce(ctx, binary, home)
		if err == nil {
			return usage, nil
		}
		lastErr = err
		if attempt == usageReadAttempts || !retryableUsageReadError(err) {
			return UsageSnapshot{}, err
		}
		if err := waitForUsageRetry(ctx, attempt); err != nil {
			return UsageSnapshot{}, usageRPCError(ctx, "", "read Codex rate limits", err)
		}
	}
	return UsageSnapshot{}, lastErr
}

func readUsageOnce(ctx context.Context, binary, home string) (UsageSnapshot, error) {
	cmd := exec.CommandContext(ctx, binary, "app-server")
	cmd.Env = environment(home)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return UsageSnapshot{}, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return UsageSnapshot{}, err
	}
	var stderr synchronizedBuffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return UsageSnapshot{}, err
	}
	defer stopUsageAppServer(cmd, stdin)

	encoder := json.NewEncoder(stdin)
	decoder := json.NewDecoder(stdout)
	if err := encoder.Encode(map[string]any{
		"method": "initialize",
		"id":     1,
		"params": map[string]any{"clientInfo": map[string]string{
			"name": "codex_account_bridge", "title": "CodexAccountBridge", "version": "1.0",
		}},
	}); err != nil {
		return UsageSnapshot{}, err
	}
	if _, err := readResponse(decoder, 1); err != nil {
		return UsageSnapshot{}, usageRPCError(ctx, stderr.String(), "initialize official Codex app-server", err)
	}
	if err := encoder.Encode(map[string]any{"method": "initialized", "params": map[string]any{}}); err != nil {
		return UsageSnapshot{}, err
	}

	if err := encoder.Encode(map[string]any{
		"method": "account/read", "id": 2, "params": map[string]bool{"refreshToken": false},
	}); err != nil {
		return UsageSnapshot{}, err
	}
	accountResponse, err := readResponse(decoder, 2)
	if err != nil {
		return UsageSnapshot{}, usageRPCError(ctx, stderr.String(), "read Codex account", err)
	}
	var account rpcAccountRead
	if err := json.Unmarshal(accountResponse.Result, &account); err != nil {
		return UsageSnapshot{}, fmt.Errorf("decode Codex account: %w", err)
	}
	if account.Account == nil || account.Account.Type != "chatgpt" {
		return UsageSnapshot{}, errors.New("ChatGPT login is required to read Codex usage")
	}

	if err := encoder.Encode(map[string]any{"method": "account/rateLimits/read", "id": 3}); err != nil {
		return UsageSnapshot{}, err
	}
	rateResponse, err := readResponse(decoder, 3)
	if err != nil {
		return UsageSnapshot{}, usageRPCError(ctx, stderr.String(), "read Codex rate limits", err)
	}
	var rateLimits rpcRateLimitResponse
	if err := json.Unmarshal(rateResponse.Result, &rateLimits); err != nil {
		return UsageSnapshot{}, fmt.Errorf("decode Codex rate limits: %w", err)
	}

	result := UsageSnapshot{
		PlanType:            account.Account.PlanType,
		RateLimits:          convertRateLimit(rateLimits.RateLimits),
		RateLimitsByLimitID: make(map[string]RateLimitSnapshot, len(rateLimits.RateLimitsByLimitID)),
		ResetCredits:        convertResetCredits(rateLimits.ResetCredits),
	}
	for id, snapshot := range rateLimits.RateLimitsByLimitID {
		result.RateLimitsByLimitID[id] = convertRateLimit(snapshot)
	}
	if result.RateLimits.PlanType == "" {
		result.RateLimits.PlanType = result.PlanType
	}
	return result, nil
}

func waitForUsageRetry(ctx context.Context, attempt int) error {
	delay := usageReadRetryDelay * time.Duration(attempt)
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func retryableUsageReadError(err error) bool {
	if err == nil || errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return false
	}
	if errors.Is(err, io.EOF) {
		return true
	}
	message := strings.ToLower(err.Error())
	for _, marker := range []string{
		"error sending request",
		"connection reset",
		"connection refused",
		"broken pipe",
		"temporarily unavailable",
		"unexpected eof",
		"timed out",
	} {
		if strings.Contains(message, marker) {
			return true
		}
	}
	return false
}

// ConsumeUsageResetCredit asks the official Codex app-server to redeem one
// rate-limit reset credit. When creditID is non-empty, it must be an opaque ID
// returned by account/rateLimits/read and selects that exact card.
func ConsumeUsageResetCredit(home, idempotencyKey, creditID string) (UsageResetOutcome, error) {
	if !validUsageResetIdempotencyKey(idempotencyKey) {
		return "", errors.New("usage reset idempotency key is invalid")
	}
	binary, err := FindReal("codex")
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(context.Background(), usageResetTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, binary, "app-server")
	cmd.Env = environment(home)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return "", err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", err
	}
	var stderr synchronizedBuffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return "", err
	}
	defer stopUsageAppServer(cmd, stdin)

	encoder := json.NewEncoder(stdin)
	decoder := json.NewDecoder(stdout)
	if err := encoder.Encode(map[string]any{
		"method": "initialize",
		"id":     1,
		"params": map[string]any{"clientInfo": map[string]string{
			"name": "codex_account_bridge", "title": "CodexAccountBridge", "version": "1.0",
		}},
	}); err != nil {
		return "", err
	}
	if _, err := readResponse(decoder, 1); err != nil {
		return "", usageRPCError(ctx, stderr.String(), "initialize official Codex app-server", err)
	}
	if err := encoder.Encode(map[string]any{"method": "initialized", "params": map[string]any{}}); err != nil {
		return "", err
	}

	if err := encoder.Encode(map[string]any{
		"method": "account/read", "id": 2, "params": map[string]bool{"refreshToken": false},
	}); err != nil {
		return "", err
	}
	accountResponse, err := readResponse(decoder, 2)
	if err != nil {
		return "", usageRPCError(ctx, stderr.String(), "read Codex account", err)
	}
	var account rpcAccountRead
	if err := json.Unmarshal(accountResponse.Result, &account); err != nil {
		return "", fmt.Errorf("decode Codex account: %w", err)
	}
	if account.Account == nil || account.Account.Type != "chatgpt" {
		return "", errors.New("ChatGPT login is required to reset Codex usage")
	}

	params := map[string]string{"idempotencyKey": idempotencyKey}
	if creditID != "" {
		params["creditId"] = creditID
	}
	if err := encoder.Encode(map[string]any{
		"method": "account/rateLimitResetCredit/consume",
		"id":     3,
		"params": params,
	}); err != nil {
		return "", err
	}
	resetResponse, err := readResponse(decoder, 3)
	if err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "method not found") {
			return "", errors.New("installed official Codex does not support usage resets; update Codex and try again")
		}
		return "", usageRPCError(ctx, stderr.String(), "reset Codex rate limits", err)
	}
	var response rpcUsageResetResponse
	if err := json.Unmarshal(resetResponse.Result, &response); err != nil {
		return "", fmt.Errorf("decode Codex usage reset result: %w", err)
	}
	switch response.Outcome {
	case UsageResetCompleted, UsageResetNothingToReset, UsageResetNoCredit, UsageResetAlreadyRedeemed:
		return response.Outcome, nil
	default:
		return "", fmt.Errorf("official Codex returned an unknown usage reset outcome %q", response.Outcome)
	}
}

func validUsageResetIdempotencyKey(value string) bool {
	if len(value) < 8 || len(value) > 128 {
		return false
	}
	for _, character := range value {
		if (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') || character == '-' || character == '_' {
			continue
		}
		return false
	}
	return true
}

// ProbeUsage sends one deliberately tiny, ephemeral request through the
// official Codex executable. It is opt-in at the caller and never persists a
// session or returns the model response. The account's auth state is selected
// only through CODEX_HOME; CAB never reads auth storage itself.
func ProbeUsage(home, model string) error {
	binary, err := FindReal("codex")
	if err != nil {
		return err
	}
	if model == "" {
		model = DefaultUsageProbeModel
	}
	tmp, err := os.MkdirTemp("", "cab-usage-probe-")
	if err != nil {
		return fmt.Errorf("create temporary usage probe workspace: %w", err)
	}
	defer os.RemoveAll(tmp)
	if err := initProbeRepository(tmp); err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), usageProbeTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary,
		"exec",
		"--ephemeral",
		"--ignore-user-config",
		"--sandbox", "read-only",
		"--model", model,
		"--cd", tmp,
		"Reply exactly OK.",
	)
	cmd.Dir = tmp
	cmd.Env = environment(home)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return fmt.Errorf("codex usage probe timed out")
		}
		return fmt.Errorf("codex usage probe failed")
	}
	return nil
}

func initProbeRepository(path string) error {
	cmd := exec.Command("/usr/bin/git", "init", "--quiet", path)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("create temporary usage probe repository: %w", err)
	}
	if _, err := os.Stat(filepath.Join(path, ".git")); err != nil {
		return fmt.Errorf("temporary usage probe repository is unavailable: %w", err)
	}
	return nil
}

func stopUsageAppServer(cmd *exec.Cmd, stdin io.Closer) {
	_ = stdin.Close()
	if cmd.Process != nil {
		_ = cmd.Process.Signal(syscall.SIGTERM)
	}
	wait := make(chan error, 1)
	go func() { wait <- cmd.Wait() }()
	select {
	case <-wait:
	case <-time.After(2 * time.Second):
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		<-wait
	}
}

func usageRPCError(ctx context.Context, stderr, action string, err error) error {
	if ctx.Err() != nil {
		return fmt.Errorf("%s: timed out", action)
	}
	detail := strings.TrimSpace(stderr)
	if detail != "" {
		return fmt.Errorf("%s: %s", action, detail)
	}
	return fmt.Errorf("%s: %w", action, err)
}

func convertRateLimit(value rpcRateLimitSnapshot) RateLimitSnapshot {
	result := RateLimitSnapshot{
		SpendControlReached: value.SpendControlReached,
	}
	if value.LimitID != nil {
		result.LimitID = *value.LimitID
	}
	if value.LimitName != nil {
		result.LimitName = *value.LimitName
	}
	if value.PlanType != nil {
		result.PlanType = *value.PlanType
	}
	if value.RateLimitReachedType != nil {
		result.RateLimitReachedType = *value.RateLimitReachedType
	}
	if value.Primary != nil {
		result.Primary = &RateLimitWindow{UsedPercent: value.Primary.UsedPercent, WindowDurationMins: value.Primary.WindowDurationMins, ResetsAt: value.Primary.ResetsAt}
	}
	if value.Secondary != nil {
		result.Secondary = &RateLimitWindow{UsedPercent: value.Secondary.UsedPercent, WindowDurationMins: value.Secondary.WindowDurationMins, ResetsAt: value.Secondary.ResetsAt}
	}
	if value.Credits != nil {
		result.Credits = &CreditsSnapshot{HasCredits: value.Credits.HasCredits, Unlimited: value.Credits.Unlimited}
		if value.Credits.Balance != nil {
			result.Credits.Balance = *value.Credits.Balance
		}
	}
	if value.IndividualLimit != nil {
		result.IndividualLimit = &SpendControlLimitSnapshot{
			Limit: value.IndividualLimit.Limit, Used: value.IndividualLimit.Used,
			RemainingPercent: value.IndividualLimit.RemainingPercent, ResetsAt: value.IndividualLimit.ResetsAt,
		}
	}
	return result
}

func convertResetCredits(value *rpcResetCreditsSummary) *ResetCreditsSummary {
	if value == nil {
		return nil
	}
	result := &ResetCreditsSummary{AvailableCount: value.AvailableCount, Credits: make([]RateLimitCredit, 0, len(value.Credits))}
	for _, credit := range value.Credits {
		item := RateLimitCredit{ID: credit.ID, ResetType: credit.ResetType, Status: credit.Status, GrantedAt: credit.GrantedAt, ExpiresAt: credit.ExpiresAt}
		if credit.Title != nil {
			item.Title = *credit.Title
		}
		if credit.Description != nil {
			item.Description = *credit.Description
		}
		result.Credits = append(result.Credits, item)
	}
	return result
}
