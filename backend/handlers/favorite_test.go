// handlers/favorite_test.go
package handlers

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reader-sync/config"
	"reader-sync/models"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/glebarez/sqlite"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// setupFavoriteTestDB 用内存 SQLite 替换全局 DB，测试结束后还原
func setupFavoriteTestDB(t *testing.T) {
	t.Helper()

	db, err := gorm.Open(sqlite.Open("file::memory:?cache=shared"), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Silent),
	})
	if err != nil {
		t.Fatalf("打开内存数据库失败: %v", err)
	}
	if err := db.AutoMigrate(&models.Favorite{}); err != nil {
		t.Fatalf("迁移收藏表失败: %v", err)
	}

	original := config.DB
	config.DB = db
	t.Cleanup(func() {
		_ = db.Migrator().DropTable(&models.Favorite{})
		config.DB = original
	})
}

// doSyncFavorites 以指定用户身份调用 SyncFavorites，返回响应体中的 data 列表
func doSyncFavorites(t *testing.T, userID string, favorites []models.Favorite) []models.Favorite {
	t.Helper()

	body, err := json.Marshal(models.SyncFavoritesRequest{Favorites: favorites})
	if err != nil {
		t.Fatalf("序列化请求失败: %v", err)
	}

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Set("user_id", userID)
	c.Request = httptest.NewRequest(http.MethodPost, "/api/v1/sync/favorites", bytes.NewReader(body))
	c.Request.Header.Set("Content-Type", "application/json")

	SyncFavorites(c)

	if w.Code != http.StatusOK {
		t.Fatalf("期望 200，实际 %d: %s", w.Code, w.Body.String())
	}

	var resp struct {
		Data []models.Favorite `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("解析响应失败: %v (%s)", err, w.Body.String())
	}
	return resp.Data
}

func TestSyncFavoritesCreatesAndReturnsList(t *testing.T) {
	setupFavoriteTestDB(t)

	now := time.Now().UnixMilli()
	list := doSyncFavorites(t, "user-a", []models.Favorite{
		{BookID: "fp-1", Title: "书一", FileName: "书一.txt", AddedAt: now, ClientUpdatedAt: now},
	})

	if len(list) != 1 {
		t.Fatalf("期望 1 条收藏，实际 %d", len(list))
	}
	if list[0].UserID != "user-a" {
		t.Errorf("user_id 应由 Token 注入，实际 %q", list[0].UserID)
	}
	if list[0].Title != "书一" {
		t.Errorf("title 不匹配: %q", list[0].Title)
	}
}

func TestSyncFavoritesLastWriteWins(t *testing.T) {
	setupFavoriteTestDB(t)

	base := time.Now().UnixMilli()
	doSyncFavorites(t, "user-a", []models.Favorite{
		{BookID: "fp-1", Title: "新标题", AddedAt: base, ClientUpdatedAt: base + 1000},
	})

	// 更旧的时间戳不应覆盖服务端记录
	list := doSyncFavorites(t, "user-a", []models.Favorite{
		{BookID: "fp-1", Title: "旧标题", AddedAt: base, ClientUpdatedAt: base},
	})
	if list[0].Title != "新标题" {
		t.Errorf("旧时间戳不应覆盖，实际 %q", list[0].Title)
	}

	// 更新的时间戳应覆盖
	list = doSyncFavorites(t, "user-a", []models.Favorite{
		{BookID: "fp-1", Title: "最新标题", AddedAt: base, ClientUpdatedAt: base + 2000},
	})
	if list[0].Title != "最新标题" {
		t.Errorf("新时间戳应覆盖，实际 %q", list[0].Title)
	}
}

func TestSyncFavoritesPropagatesTombstone(t *testing.T) {
	setupFavoriteTestDB(t)

	base := time.Now().UnixMilli()
	doSyncFavorites(t, "user-a", []models.Favorite{
		{BookID: "fp-1", Title: "书一", AddedAt: base, ClientUpdatedAt: base},
	})

	// 设备 A 取消收藏
	doSyncFavorites(t, "user-a", []models.Favorite{
		{BookID: "fp-1", Title: "书一", AddedAt: base, ClientUpdatedAt: base + 1000, IsDeleted: true},
	})

	// 设备 B 上报旧的未删除副本，服务端应继续下发墓碑
	list := doSyncFavorites(t, "user-a", []models.Favorite{
		{BookID: "fp-1", Title: "书一", AddedAt: base, ClientUpdatedAt: base},
	})
	if len(list) != 1 || !list[0].IsDeleted {
		t.Fatalf("墓碑应保留并下发，实际 %+v", list)
	}
}

func TestSyncFavoritesDropsExpiredTombstone(t *testing.T) {
	setupFavoriteTestDB(t)

	expired := time.Now().Add(-favoriteTombstoneTTL - time.Hour).UnixMilli()
	list := doSyncFavorites(t, "user-a", []models.Favorite{
		{BookID: "fp-1", Title: "书一", AddedAt: expired, ClientUpdatedAt: expired, IsDeleted: true},
	})
	if len(list) != 0 {
		t.Fatalf("过期墓碑不应入库，实际 %+v", list)
	}
}

func TestFavoritesAreIsolatedPerUser(t *testing.T) {
	setupFavoriteTestDB(t)

	now := time.Now().UnixMilli()
	doSyncFavorites(t, "user-a", []models.Favorite{
		{BookID: "fp-1", Title: "A 的书", AddedAt: now, ClientUpdatedAt: now},
	})
	list := doSyncFavorites(t, "user-b", []models.Favorite{
		{BookID: "fp-2", Title: "B 的书", AddedAt: now, ClientUpdatedAt: now},
	})

	if len(list) != 1 || list[0].BookID != "fp-2" {
		t.Fatalf("用户数据未隔离，实际 %+v", list)
	}
}

func TestSyncFavoritesRejectsAnonymous(t *testing.T) {
	setupFavoriteTestDB(t)

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodPost, "/api/v1/sync/favorites", bytes.NewReader([]byte(`{"favorites":[]}`)))
	c.Request.Header.Set("Content-Type", "application/json")

	SyncFavorites(c)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("缺少身份时应返回 401，实际 %d", w.Code)
	}
}

func TestGetFavoritesReturnsEmptyArray(t *testing.T) {
	setupFavoriteTestDB(t)

	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Set("user_id", "user-a")
	c.Request = httptest.NewRequest(http.MethodGet, "/api/v1/sync/favorites", nil)

	GetFavorites(c)

	if w.Code != http.StatusOK {
		t.Fatalf("期望 200，实际 %d: %s", w.Code, w.Body.String())
	}
	if got := w.Body.String(); got != `{"data":[]}` {
		t.Errorf("无数据时应返回空数组，实际 %s", got)
	}
}
