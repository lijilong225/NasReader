package handlers

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPruneEmptyDirs(t *testing.T) {
	root := t.TempDir()

	// 有书的目录保留，模拟文件被 NAS 直接删掉后剩下的空目录应被清掉
	keepDir := filepath.Join(root, "科幻")
	if err := os.MkdirAll(keepDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(keepDir, "三体.epub"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	emptyNested := filepath.Join(root, "历史", "断代史")
	if err := os.MkdirAll(emptyNested, 0o755); err != nil {
		t.Fatal(err)
	}

	removed, err := pruneEmptyDirs(root)
	if err != nil {
		t.Fatalf("pruneEmptyDirs 返回错误: %v", err)
	}
	if len(removed) != 2 {
		t.Fatalf("应清理 2 个空目录，实际 %d: %v", len(removed), removed)
	}

	if _, err := os.Stat(filepath.Join(root, "历史")); !os.IsNotExist(err) {
		t.Fatal("空的父目录应被一并清理")
	}
	if _, err := os.Stat(filepath.Join(keepDir, "三体.epub")); err != nil {
		t.Fatal("含书籍的目录不应被清理")
	}
	if _, err := os.Stat(root); err != nil {
		t.Fatal("垃圾箱根目录本身不应被删除")
	}
}
