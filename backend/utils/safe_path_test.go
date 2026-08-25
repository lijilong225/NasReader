package utils

import (
	"os"
	"path/filepath"
	"testing"
)

func TestGetNasRootDir(t *testing.T) {
	t.Setenv("NAS_BOOKS_DIR", "")
	if got := GetNasRootDir(); got != "/data/books" {
		t.Fatalf("未设置环境变量时应回退默认挂载点，得到 %q", got)
	}

	t.Setenv("NAS_BOOKS_DIR", "/nas/books/")
	if got := GetNasRootDir(); got != "/nas/books" {
		t.Fatalf("应清理尾部斜杠，得到 %q", got)
	}
}

func TestSafeResolvePathAllowsInRoot(t *testing.T) {
	t.Setenv("NAS_BOOKS_DIR", "/nas/books")

	cases := map[string]string{
		"":                  "/nas/books",
		"a.txt":             "/nas/books/a.txt",
		"/a.txt":            "/nas/books/a.txt",
		"sub/dir/b.epub":    "/nas/books/sub/dir/b.epub",
		"./sub/./c.txt":     "/nas/books/sub/c.txt",
		"sub/../d.txt":      "/nas/books/d.txt",
		"中文 目录/带空格.txt": "/nas/books/中文 目录/带空格.txt",
	}

	for input, want := range cases {
		got, err := SafeResolvePath(input)
		if err != nil {
			t.Fatalf("SafeResolvePath(%q) 意外报错: %v", input, err)
		}
		if got != want {
			t.Fatalf("SafeResolvePath(%q) = %q, 期望 %q", input, got, want)
		}
	}
}

func TestSafeResolvePathRejectsTraversal(t *testing.T) {
	t.Setenv("NAS_BOOKS_DIR", "/nas/books")

	// filepath.Clean("/"+userPath) 会把越界的 .. 折叠掉，最终必须落在根目录内
	inputs := []string{
		"../etc/passwd",
		"../../../../etc/passwd",
		"sub/../../etc/passwd",
		"/../etc/passwd",
	}

	for _, input := range inputs {
		got, err := SafeResolvePath(input)
		if err != nil {
			continue // 显式拒绝，符合预期
		}
		if rel, relErr := filepath.Rel("/nas/books", got); relErr != nil ||
			rel == ".." || len(rel) > 2 && rel[:3] == ".."+string(filepath.Separator) {
			t.Fatalf("SafeResolvePath(%q) = %q 越出根目录", input, got)
		}
	}
}

func TestSafeResolvePathUsesEnvRoot(t *testing.T) {
	root := t.TempDir()
	t.Setenv("NAS_BOOKS_DIR", root)

	got, err := SafeResolvePath("books/a.txt")
	if err != nil {
		t.Fatalf("意外报错: %v", err)
	}
	want := filepath.Join(root, "books", "a.txt")
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}

	if _, err := os.Stat(root); err != nil {
		t.Fatalf("临时根目录应存在: %v", err)
	}
}
