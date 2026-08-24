package handlers

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"utils"

	"github.com/gin-gonic/gin"
)

// NAS 根目录路径（可通过环境变量配置）
var NASBasePath = getEnv("NAS_BOOKS_DIR", "/nas/books")

func getEnv(key, fallback string) string {
	if val, ok := os.LookupEnv(key); ok {
		return val
	}
	return fallback
}

// FileNode 目录树节点结构
type FileNode struct {
	Name      string `json:"name"`
	Path      string `json:"path"` // 相对路径，如 /科幻/三体.epub
	IsDir     bool   `json:"is_dir"`
	Size      int64  `json:"size"`
	Extension string `json:"extension,omitempty"` // txt / epub
	BookID    string `json:"book_id,omitempty"`   // 文件的唯一指纹（用于进度同步）
	ModTime   int64  `json:"mod_time"`
}

// BrowseDirectory 浏览目录（支持子目录分页/原样透传）
func BrowseDirectory(c *gin.Context) {
	targetDir, err := utils.SafeResolvePath(c.DefaultQuery("path", "/"))
	if err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": err.Error()})
		return
	}
	entries, err := os.ReadDir(targetDir)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "目录不存在或无法读取"})
		return
	}

	relPath := c.DefaultQuery("path", "/")

	// 路径防穿透安全检查
	cleanRelPath := filepath.Clean(relPath)
	if strings.HasPrefix(cleanRelPath, "..") {
		c.JSON(http.StatusBadRequest, gin.H{"error": "Invalid directory path"})
		return
	}

	targetDir := filepath.Join(NASBasePath, cleanRelPath)
	entries, err := os.ReadDir(targetDir)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": fmt.Sprintf("Directory not found: %v", err)})
		return
	}

	var nodes []FileNode
	for _, entry := range entries {
		// 忽略隐藏文件/文件夹（如 .DS_Store, .git 等）
		if strings.HasPrefix(entry.Name(), ".") {
			continue
		}

		entryPath := filepath.Join(cleanRelPath, entry.Name())
		info, err := entry.Info()
		if err != nil {
			continue
		}

		if entry.IsDir() {
			nodes = append(nodes, FileNode{
				Name:    entry.Name(),
				Path:    entryPath,
				IsDir:   true,
				Size:    0,
				ModTime: info.ModTime().UnixMilli(),
			})
		} else {
			ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(entry.Name()), "."))
			// 只保留 txt 和 epub
			if ext == "txt" || ext == "epub" {
				fullFilePath := filepath.Join(targetDir, entry.Name())
				bookID := GenerateFastFileFingerprint(fullFilePath, info.Size())

				nodes = append(nodes, FileNode{
					Name:      entry.Name(),
					Path:      entryPath,
					IsDir:     false,
					Size:      info.Size(),
					Extension: ext,
					BookID:    bookID,
					ModTime:   info.ModTime().UnixMilli(),
				})
			}
		}
	}

	c.JSON(http.StatusOK, gin.H{
		"current_path": cleanRelPath,
		"items":        nodes,
	})
}

func DownloadFile(c *gin.Context) {
	relPath := c.Query("path")
	if relPath == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "缺少 path 参数"})
		return
	}

	// 1. 使用 safe_path 校验并解析目标绝对路径
	targetFilePath, err := utils.SafeResolvePath(relPath)
	if err != nil {
		c.JSON(http.StatusForbidden, gin.H{"error": err.Error()})
		return
	}

	// 2. 检查目标是否存在且非目录
	fileInfo, err := os.Stat(targetFilePath)
	if err != nil {
		if os.IsNotExist(err) {
			c.JSON(http.StatusNotFound, gin.H{"error": "文件不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "无法读取文件信息"})
		return
	}

	if fileInfo.IsDir() {
		c.JSON(http.StatusBadRequest, gin.H{"error": "目标为目录，不支持直接下载"})
		return
	}

	// 3. 电子书格式白名单（防止暴露同目录下的 .nfo, .json, .sh 等文件）
	ext := strings.ToLower(filepath.Ext(targetFilePath))
	if ext != ".txt" && ext != ".epub" {
		c.JSON(http.StatusForbidden, gin.H{"error": "不支持下载非电子书文件"})
		return
	}

	// 4. 设置安全下载头（兼容中文文件名）
	filename := filepath.Base(targetFilePath)
	c.Header("Content-Disposition", "attachment; filename*=UTF-8''"+url.PathEscape(filename))

	// 5. 传输文件（支持 HTTP Range 断点续传）
	c.File(targetFilePath)
}

// GenerateFastFileFingerprint 快速指纹算法：SHA256(前4KB + 后4KB + 文件大小)
func GenerateFastFileFingerprint(filePath string, size int64) string {
	file, err := os.Open(filePath)
	if err != nil {
		return ""
	}
	defer file.Close()

	hasher := sha256.New()
	headBuf := make([]byte, 4096)
	n, _ := file.Read(headBuf)
	hasher.Write(headBuf[:n])

	if size > 4096 {
		tailBuf := make([]byte, 4096)
		offset := size - 4096
		if offset < 4096 {
			offset = 4096
		}
		_, _ = file.Seek(offset, io.SeekStart)
		n, _ = file.Read(tailBuf)
		hasher.Write(tailBuf[:n])
	}

	hasher.Write([]byte(fmt.Sprintf("%d", size)))
	return hex.EncodeToString(hasher.Sum(nil))
}