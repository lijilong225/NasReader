// handlers/trash.go
package handlers

import (
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"reader-sync/utils"
	"sort"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

type MoveToTrashRequest struct {
	Path string `json:"path" binding:"required"`
}

// MoveToTrash 把 NAS 书库中的电子书移动到根目录下的 .trashBin，保留原有子目录层级
func MoveToTrash(c *gin.Context) {
	var req MoveToTrashRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数无效: " + err.Error()})
		return
	}

	relPath := utils.NormalizeRelPath(req.Path)
	if relPath == "/" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "不允许操作书库根目录"})
		return
	}
	if utils.IsInTrashBin(relPath) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "该文件已在垃圾箱中"})
		return
	}
	if !utils.IsHiddenPathAllowed(relPath) {
		c.JSON(http.StatusForbidden, gin.H{"error": "不允许操作隐藏目录"})
		return
	}

	srcPath, err := utils.SafeResolvePath(relPath)
	if err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": err.Error()})
		return
	}

	info, err := os.Stat(srcPath)
	if err != nil {
		if os.IsNotExist(err) {
			c.JSON(http.StatusNotFound, gin.H{"error": "文件不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法读取文件信息"})
		return
	}
	if info.IsDir() {
		c.JSON(http.StatusBadRequest, gin.H{"error": "暂不支持将文件夹移入垃圾箱"})
		return
	}

	ext := strings.ToLower(filepath.Ext(srcPath))
	if ext != ".txt" && ext != ".epub" {
		c.JSON(http.StatusForbidden, gin.H{"error": "仅支持移动电子书文件"})
		return
	}

	trashRoot, err := utils.ResolveTrashBinDir()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法创建垃圾箱目录: " + err.Error()})
		return
	}

	// 保留原目录结构，便于在垃圾箱里辨认书籍来源
	relDir := filepath.Dir(strings.TrimPrefix(relPath, "/"))
	destDir := trashRoot
	if relDir != "." && relDir != "" {
		destDir = filepath.Join(trashRoot, relDir)
	}
	if err := os.MkdirAll(destDir, 0o755); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法创建垃圾箱子目录: " + err.Error()})
		return
	}

	destPath := uniqueDestPath(destDir, filepath.Base(srcPath))
	if err := moveFile(srcPath, destPath); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "移动到垃圾箱失败: " + err.Error()})
		return
	}

	nasRoot := utils.GetNasRootDir()
	trashRel, relErr := filepath.Rel(nasRoot, destPath)
	if relErr != nil {
		trashRel = filepath.Join(utils.TrashBinDirName, filepath.Base(destPath))
	}

	c.JSON(http.StatusOK, gin.H{
		"code":       200,
		"message":    "已移动到垃圾箱",
		"trash_path": "/" + filepath.ToSlash(trashRel),
	})
}

type RestoreFromTrashRequest struct {
	Path string `json:"path" binding:"required"`
}

// RestoreFromTrash 把垃圾箱中的电子书还原到它在书库中的原始目录
func RestoreFromTrash(c *gin.Context) {
	var req RestoreFromTrashRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求参数无效: " + err.Error()})
		return
	}

	relPath := utils.NormalizeRelPath(req.Path)
	if !utils.IsInTrashBin(relPath) || relPath == "/"+utils.TrashBinDirName {
		c.JSON(http.StatusBadRequest, gin.H{"error": "只能恢复垃圾箱内的文件"})
		return
	}
	if !utils.IsHiddenPathAllowed(relPath) {
		c.JSON(http.StatusForbidden, gin.H{"error": "不允许操作隐藏目录"})
		return
	}

	srcPath, err := utils.SafeResolvePath(relPath)
	if err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": err.Error()})
		return
	}

	info, err := os.Stat(srcPath)
	if err != nil {
		if os.IsNotExist(err) {
			c.JSON(http.StatusNotFound, gin.H{"error": "文件不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法读取文件信息"})
		return
	}
	if info.IsDir() {
		c.JSON(http.StatusBadRequest, gin.H{"error": "暂不支持恢复文件夹"})
		return
	}

	ext := strings.ToLower(filepath.Ext(srcPath))
	if ext != ".txt" && ext != ".epub" {
		c.JSON(http.StatusForbidden, gin.H{"error": "仅支持恢复电子书文件"})
		return
	}

	// 去掉垃圾箱前缀即得原始位置，移入时保留的子目录层级在此还原
	originRel := strings.TrimPrefix(relPath, "/"+utils.TrashBinDirName)
	destPath, err := utils.SafeResolvePath(originRel)
	if err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": err.Error()})
		return
	}

	destDir := filepath.Dir(destPath)
	if err := os.MkdirAll(destDir, 0o755); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法创建目标目录: " + err.Error()})
		return
	}

	finalPath := uniqueDestPath(destDir, filepath.Base(destPath))
	if err := moveFile(srcPath, finalPath); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "恢复失败: " + err.Error()})
		return
	}

	restoredRel, relErr := filepath.Rel(utils.GetNasRootDir(), finalPath)
	if relErr != nil {
		restoredRel = filepath.Base(finalPath)
	}

	c.JSON(http.StatusOK, gin.H{
		"code":          200,
		"message":       "已恢复到书库",
		"restored_path": "/" + filepath.ToSlash(restoredRel),
	})
}

// RefreshTrashBin 清理垃圾箱残留：书籍被 NAS 文件管理器直接删除后，其所在的空目录会留在垃圾箱里
func RefreshTrashBin(c *gin.Context) {
	trashRoot, err := utils.ResolveTrashBinDir()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法创建垃圾箱目录: " + err.Error()})
		return
	}

	removed, err := pruneEmptyDirs(trashRoot)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "清理垃圾箱失败: " + err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"code":          200,
		"message":       "垃圾箱已刷新",
		"removed_count": len(removed),
		"removed_dirs":  removed,
	})
}

// pruneEmptyDirs 自底向上删除 root 内已空的子目录，root 自身保留，返回被删目录的相对路径
func pruneEmptyDirs(root string) ([]string, error) {
	var dirs []string
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() && path != root {
			dirs = append(dirs, path)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}

	// 深的先删，父目录才可能随之变空
	sort.Slice(dirs, func(i, j int) bool { return len(dirs[i]) > len(dirs[j]) })

	removed := make([]string, 0)
	for _, dir := range dirs {
		entries, readErr := os.ReadDir(dir)
		if readErr != nil || len(entries) > 0 {
			continue
		}
		if os.Remove(dir) != nil {
			continue
		}
		rel, relErr := filepath.Rel(root, dir)
		if relErr != nil {
			rel = filepath.Base(dir)
		}
		removed = append(removed, "/"+utils.TrashBinDirName+"/"+filepath.ToSlash(rel))
	}
	return removed, nil
}

// uniqueDestPath 同名文件追加时间戳，避免覆盖目标目录中已有的同名书籍
func uniqueDestPath(dir, name string) string {
	candidate := filepath.Join(dir, name)
	if _, err := os.Stat(candidate); os.IsNotExist(err) {
		return candidate
	}

	ext := filepath.Ext(name)
	base := strings.TrimSuffix(name, ext)
	stamp := time.Now().Format("20060102-150405")
	for i := 0; ; i++ {
		suffix := stamp
		if i > 0 {
			suffix = fmt.Sprintf("%s-%d", stamp, i)
		}
		candidate = filepath.Join(dir, fmt.Sprintf("%s_%s%s", base, suffix, ext))
		if _, err := os.Stat(candidate); os.IsNotExist(err) {
			return candidate
		}
	}
}

// moveFile 优先用 rename，跨设备（EXDEV）时退化为复制后删除
func moveFile(src, dest string) error {
	if err := os.Rename(src, dest); err == nil {
		return nil
	}

	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.OpenFile(dest, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}

	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(dest)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(dest)
		return err
	}

	return os.Remove(src)
}
