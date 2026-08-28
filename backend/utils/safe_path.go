// utils/safe_path.go
package utils

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// 获取 NAS 书籍根目录（优先从环境变量读取）
func GetNasRootDir() string {
	root := os.Getenv("NAS_BOOKS_DIR")
	if root == "" {
		root = "/data/books" // 默认容器挂载点
	}
	return filepath.Clean(root)
}

// SafeResolvePath 强制校验路径合法性，拦截任何跳出根目录的攻击
func SafeResolvePath(userPath string) (string, error) {
	nasRoot := GetNasRootDir()

	// 拼接并规范化绝对路径
	cleanUserPath := filepath.Clean("/" + userPath)
	targetPath := filepath.Join(nasRoot, cleanUserPath)

	// 计算相对路径：如果包含 .. 说明尝试向上越界
	rel, err := filepath.Rel(nasRoot, targetPath)
	if err != nil || strings.HasPrefix(rel, "..") {
		return "", errors.New("非法访问：检测到跨目录遍历攻击")
	}

	return targetPath, nil
}

// TrashBinDirName 垃圾箱目录名，位于 NAS 根目录下且不出现在常规目录浏览结果中
const TrashBinDirName = ".trashBin"

// NormalizeRelPath 归一化用户传入的相对路径为以 / 开头的 slash 分隔形式
func NormalizeRelPath(userPath string) string {
	return filepath.ToSlash(filepath.Clean("/" + userPath))
}

// IsHiddenPathAllowed 隐藏路径一律拒绝，仅放行根目录下的垃圾箱这一个例外
func IsHiddenPathAllowed(relPath string) bool {
	segments := strings.Split(strings.Trim(NormalizeRelPath(relPath), "/"), "/")
	for i, seg := range segments {
		if seg == "" || !strings.HasPrefix(seg, ".") {
			continue
		}
		if i != 0 || seg != TrashBinDirName {
			return false
		}
	}
	return true
}

// IsInTrashBin 判断相对路径是否指向垃圾箱本身或其内部
func IsInTrashBin(relPath string) bool {
	norm := NormalizeRelPath(relPath)
	return norm == "/"+TrashBinDirName || strings.HasPrefix(norm, "/"+TrashBinDirName+"/")
}

// ResolveTrashBinDir 返回垃圾箱物理目录，必要时创建
func ResolveTrashBinDir() (string, error) {
	dir := filepath.Join(GetNasRootDir(), TrashBinDirName)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	return dir, nil
}
