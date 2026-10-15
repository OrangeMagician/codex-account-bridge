package worktree

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func testRepo(t *testing.T) (string, string) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("Git not installed")
	}
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	repo := filepath.Join(root, "repo")
	data := filepath.Join(root, "data")
	for _, p := range []string{repo, data} {
		if err = os.Mkdir(p, 0700); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = git("-C", repo, "init"); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(repo, "file.txt"), []byte("initial"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = git("-C", repo, "add", "file.txt"); err != nil {
		t.Fatal(err)
	}
	if _, err = git("-C", repo, "-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "-m", "initial"); err != nil {
		t.Fatal(err)
	}
	return repo, data
}

func TestCreateRemovePreservesCommitsAndDoesNotRunHooks(t *testing.T) {
	repo, data := testRepo(t)
	marker := filepath.Join(filepath.Dir(repo), "hook-ran")
	if err := os.WriteFile(filepath.Join(repo, ".git/hooks/post-checkout"), []byte("#!/bin/sh\ntouch '"+marker+"'\n"), 0700); err != nil {
		t.Fatal(err)
	}
	e, err := Create(data, "work", repo, "HEAD")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("hook was executed")
	}
	list, err := List(data, "work")
	if err != nil || len(list) != 1 {
		t.Fatal(list, err)
	}
	other, err := List(data, "other")
	if err != nil || len(other) != 0 {
		t.Fatal(other, err)
	}
	if err = os.WriteFile(filepath.Join(e.Path, "untracked"), []byte("save me"), 0600); err != nil {
		t.Fatal(err)
	}
	if err = Remove(data, "work", e.ID); err == nil {
		t.Fatal("dirty worktree removed")
	}
	if _, err = git("-C", e.Path, "add", "untracked"); err != nil {
		t.Fatal(err)
	}
	if _, err = git("-C", e.Path, "-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "-m", "saved work"); err != nil {
		t.Fatal(err)
	}
	if err = Remove(data, "other", e.ID); err == nil {
		t.Fatal("another account removed worktree")
	}
	if err = Remove(data, "work", e.ID); err != nil {
		t.Fatal(err)
	}
	if _, err = os.Stat(e.Path); !os.IsNotExist(err) {
		t.Fatal("checkout remains")
	}
	commit, err := git("-C", repo, "show", "refs/cab/worktree-archives/"+e.ID+":untracked")
	if err != nil || string(commit) != "save me" {
		t.Fatal("committed work lost", err)
	}
}

func TestWorktreeRegistrationCannotEscapeOrFollowSymlinks(t *testing.T) {
	if validateCheckoutPaths([]byte("nested/Auth.json\x00")) == nil {
		t.Fatal("authentication filename allowed in checkout")
	}
	if validateCheckoutPaths([]byte("src/app.go\x00")) != nil {
		t.Fatal("ordinary checkout rejected")
	}
	repo, data := testRepo(t)
	if _, err := Create(data, "work", repo, "--upload-pack=evil"); err == nil {
		t.Fatal("option ref accepted")
	}
	root, err := registry(data, true)
	if err != nil {
		t.Fatal(err)
	}
	id := strings.Repeat("a", 32)
	if err = os.Symlink(filepath.Join(repo, "file.txt"), filepath.Join(root, id+".json")); err != nil {
		t.Fatal(err)
	}
	if _, err = List(data, "work"); err == nil {
		t.Fatal("symlink registration read")
	}
	if err = Remove(data, "work", "../../outside"); err == nil {
		t.Fatal("path ID accepted")
	}
}
