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