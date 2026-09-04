// handlers/search_test.go
package handlers

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reader-sync/utils"
	"testing"

	"github.com/gin-gonic/gin"
)

// setupSearchLibrary 造一个临时书库：多层目录、非书文件、垃圾箱与隐藏目录
func setupSearchLibrary(t *testing.T) string {
	t.Helper()

	root := t.TempDir()
	files := map[string]string{
		filepath.Join("科幻", "三体.epub"):                          "第一部",
		filepath.Join("科幻", "三体2 黑暗森林.txt"):                     "第二部",
		filepath.Join("科幻", "外国", "沙丘.pdf"):                     "dune",
		filepath.Join("历史", "万历十五年.epub"):                       "history",
		filepath.Join("科幻", "封面.jpg"):                           "not-a-book",
		filepath.Join(utils.TrashBinDirName, "三体已删除.epub"):      "trashed",
		filepath.Join(utils.TrashBinDirName, "科幻", "三体旧版.epub"): "trashed-nested",
		filepath.Join(".cache", "三体缓存.txt"):                     "hidden",
	}

	for rel, content := range files {
		full := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatalf("创建目录失败: %v", err)
		}
		if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
			t.Fatalf("写入文件失败: %v", err)
		}
	}

	t.Setenv("NAS_BOOKS_DIR", root)
	return root
}

// doSearch 调用 SearchBooks，返回状态码与解析后的响应
func doSearch(t *testing.T, query string) (int, struct {
	Keyword   string     `json:"keyword"`
	Items     []FileNode `json:"items"`
	Truncated bool       `json:"truncated"`
	Error     string     `json:"error"`
}) {
	t.Helper()

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Set("user_id", "user-a")
	c.Request = httptest.NewRequest(http.MethodGet, "/api/v1/files/search?"+query, nil)

	SearchBooks(c)

	var resp struct {
		Keyword   string     `json:"keyword"`
		Items     []FileNode `json:"items"`
		Truncated bool       `json:"truncated"`
		Error     string     `json:"error"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("解析响应失败: %v (%s)", err, w.Body.String())
	}
	return w.Code, resp
}

func TestSearchBooksMatchesAcrossWholeLibrary(t *testing.T) {
	setupSearchLibrary(t)

	code, resp := doSearch(t, "q=%E4%B8%89%E4%BD%93") // 三体
	if code != http.StatusOK {
		t.Fatalf("期望 200，实际 %d: %q", code, resp.Error)
	}
	if resp.Keyword != "三体" {
		t.Fatalf("回显关键词应为 三体，实际 %q", resp.Keyword)
	}
	if len(resp.Items) != 2 {
		t.Fatalf("应命中 2 本书，实际 %d: %+v", len(resp.Items), resp.Items)
	}

	paths := map[string]bool{}
	for _, item := range resp.Items {
		paths[item.Path] = true
		if item.IsDir {
			t.Fatalf("搜索结果不应包含目录: %q", item.Path)
		}
		if item.BookID == "" {
			t.Fatalf("搜索结果缺少文件指纹: %q", item.Path)
		}
		if item.Size <= 0 {
			t.Fatalf("搜索结果缺少文件大小: %q", item.Path)
		}
	}
	if !paths["/科幻/三体.epub"] || !paths["/科幻/三体2 黑暗森林.txt"] {
		t.Fatalf("命中路径不符合预期: %+v", paths)
	}
}

func TestSearchBooksSkipsTrashAndHiddenAndNonBooks(t *testing.T) {
	setupSearchLibrary(t)

	// 关键词能同时匹配垃圾箱与隐藏目录里的文件，用于验证它们确实被跳过
	_, resp := doSearch(t, "q=%E4%B8%89%E4%BD%93") // 三体
	for _, item := range resp.Items {
		if item.Path == "/.trashBin/三体已删除.epub" ||
			item.Path == "/.trashBin/科幻/三体旧版.epub" {
			t.Fatalf("垃圾箱内的书籍不应出现在搜索结果中: %q", item.Path)
		}
		if item.Path == "/.cache/三体缓存.txt" {
			t.Fatalf("隐藏目录内的文件不应出现在搜索结果中: %q", item.Path)
		}
	}

	_, imgResp := doSearch(t, "q=%E5%B0%81%E9%9D%A2") // 封面
	if len(imgResp.Items) != 0 {
		t.Fatalf("非电子书文件不应被搜索到，实际 %+v", imgResp.Items)
	}
}

func TestSearchBooksIsCaseInsensitive(t *testing.T) {
	setupSearchLibrary(t)

	_, resp := doSearch(t, "q=DUNE")
	if len(resp.Items) != 0 {
		t.Fatalf("英文关键词按文件名匹配，不应命中中文书名: %+v", resp.Items)
	}

	_, pdfResp := doSearch(t, "q=%E6%B2%99%E4%B8%98") // 沙丘
	if len(pdfResp.Items) != 1 || pdfResp.Items[0].Extension != "pdf" {
		t.Fatalf("应命中 1 个 pdf，实际 %+v", pdfResp.Items)
	}
	if pdfResp.Items[0].Path != "/科幻/外国/沙丘.pdf" {
		t.Fatalf("深层目录路径不正确: %q", pdfResp.Items[0].Path)
	}
}

func TestSearchBooksRejectsEmptyKeyword(t *testing.T) {
	setupSearchLibrary(t)

	code, resp := doSearch(t, "q=%20%20")
	if code != http.StatusBadRequest {
		t.Fatalf("空关键词应返回 400，实际 %d", code)
	}
	if resp.Error == "" {
		t.Fatal("空关键词应返回错误说明")
	}
}

func TestSearchBooksRespectsLimit(t *testing.T) {
	setupSearchLibrary(t)

	// 关键词 . 能匹配全部书籍（扩展名的点号），用 limit=1 验证截断标记
	code, resp := doSearch(t, "q=.&limit=1")
	if code != http.StatusOK {
		t.Fatalf("期望 200，实际 %d: %q", code, resp.Error)
	}
	if len(resp.Items) != 1 {
		t.Fatalf("limit=1 时应只返回 1 条，实际 %d", len(resp.Items))
	}
	if !resp.Truncated {
		t.Fatal("结果被截断时应返回 truncated=true")
	}
}
