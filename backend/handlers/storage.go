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

// DownloadFile 支持 Range 断点续传的文件下载接口
func DownloadFile(c *gin.Context) {
	relPath := c.Query("path")
	if relPath == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "Path parameter is required"})
		return
	}

	cleanRelPath := filepath.Clean(relPath)
	if strings.HasPrefix(cleanRelPath, "..") {
		c.JSON(http.StatusBadRequest, gin.H{"error": "Invalid file path"})
		return
	}

	targetFilePath := filepath.Join(NASBasePath, cleanRelPath)
	fileInfo, err := os.Stat(targetFilePath)
	if err != nil || fileInfo.IsDir() {
		c.JSON(http.StatusNotFound, gin.H{"error": "File not found"})
		return
	}

	// c.File 会自动处理 HTTP Range（断点续传）和 Content-Type
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