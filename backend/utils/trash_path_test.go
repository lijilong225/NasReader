package utils

import "testing"

func TestIsHiddenPathAllowed(t *testing.T) {
	allowed := []string{
		"/",
		"/科幻/三体.epub",
		"/.trashBin",
		"/.trashBin/科幻/三体.epub",
	}
	for _, p := range allowed {
		if !IsHiddenPathAllowed(p) {
			t.Fatalf("IsHiddenPathAllowed(%q) 应为 true", p)
		}
	}

	rejected := []string{
		"/.git",
		"/.git/config",
		"/科幻/.hidden/a.txt",
		"/.ssh/id_rsa",
		"/科幻/.trashBin/a.txt",
	}
	for _, p := range rejected {
		if IsHiddenPathAllowed(p) {
			t.Fatalf("IsHiddenPathAllowed(%q) 应为 false", p)
		}
	}
}

func TestIsInTrashBin(t *testing.T) {
	if !IsInTrashBin("/.trashBin") || !IsInTrashBin(".trashBin/a.txt") {
		t.Fatal("垃圾箱自身及其子路径应判定为 true")
	}
	if IsInTrashBin("/科幻/a.txt") || IsInTrashBin("/.trashBinOther/a.txt") {
		t.Fatal("非垃圾箱路径应判定为 false")
	}
}

func TestResolveTrashBinDirCreatesDir(t *testing.T) {
	root := t.TempDir()
	t.Setenv("NAS_BOOKS_DIR", root)

	dir, err := ResolveTrashBinDir()
	if err != nil {
		t.Fatalf("意外报错: %v", err)
	}
	if dir != root+"/"+TrashBinDirName {
		t.Fatalf("垃圾箱路径错误: %q", dir)
	}
	// 幂等：已存在时不应报错
	if _, err := ResolveTrashBinDir(); err != nil {
		t.Fatalf("重复调用报错: %v", err)
	}
}
