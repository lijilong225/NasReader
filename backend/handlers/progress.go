package handlers

import (
    "crypto/rand"
    "encoding/hex"
    "net/http"
    "reader-sync/config"
    "reader-sync/models"
    "time"

    "github.com/gin-gonic/gin"
    "gorm.io/gorm"
    "gorm.io/gorm/clause"
)

type SyncProgressRequest struct {
    BookID          string  `json:"book_id" binding:"required"`
    Title           string  `json:"title"`
    FilePath        string  `json:"file_path"`
    Progress        float64 `json:"progress" binding:"min=0,max=1"`
    Locator         string  `json:"locator" binding:"required"`
    DeviceID        string  `json:"device_id" binding:"required"`
    DeviceName      string  `json:"device_name"`
    ClientUpdatedAt int64   `json:"client_updated_at" binding:"required"`
}

// GetProgress 获取单本书的最新阅读进度
func GetProgress(c *gin.Context) {
    userID := c.GetString("user_id")
    bookID := c.Param("book_id")

    var progress models.ReadingProgress
    err := config.DB.Where("user_id = ? AND book_id = ?", userID, bookID).First(&progress).Error
    if err != nil {
        if err == gorm.ErrRecordNotFound {
            c.JSON(http.StatusNotFound, gin.H{"message": "No reading progress found for this book"})
            return
        }
        c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
        return
    }

    c.JSON(http.StatusOK, progress)
}

// GetAllProgress 获取用户所有书籍的最新进度（用于冷启动同步）
func GetAllProgress(c *gin.Context) {
    userID := c.GetString("user_id")

    var progressList []models.ReadingProgress
    if err := config.DB.Where("user_id = ?", userID).Find(&progressList).Error; err != nil {
        c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
        return
    }

    c.JSON(http.StatusOK, gin.H{"data": progressList})
}

// SyncProgress 上报并合并阅读进度 (LWW 策略)
func SyncProgress(c *gin.Context) {
    userID := c.GetString("user_id")

    var req SyncProgressRequest
    if err := c.ShouldBindJSON(&req); err != nil {
        c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
        return
    }

    randomBytes := make([]byte, 16)
    _, _ = rand.Read(randomBytes)

    now := time.Now()
    incoming := models.ReadingProgress{
        ID:              hex.EncodeToString(randomBytes),
        UserID:          userID,
        BookID:          req.BookID,
        Title:           req.Title,
        FilePath:        req.FilePath,
        Progress:        req.Progress,
        Locator:         req.Locator,
        DeviceID:        req.DeviceID,
        DeviceName:      req.DeviceName,
        ClientUpdatedAt: req.ClientUpdatedAt,
        UpdatedAt:       now,
    }

    // 单条 upsert：唯一索引 idx_progress_user_book 保证并发首次上报不会插出重复行，
    // DO UPDATE 的 WHERE 即 LWW 判定，时间戳不够新时 RowsAffected 为 0。
    result := config.DB.Clauses(clause.OnConflict{
        Columns: []clause.Column{{Name: "user_id"}, {Name: "book_id"}},
        DoUpdates: clause.Assignments(map[string]interface{}{
            "title":             req.Title,
            "file_path":         req.FilePath,
            "progress":          req.Progress,
            "locator":           req.Locator,
            "device_id":         req.DeviceID,
            "device_name":       req.DeviceName,
            "client_updated_at": req.ClientUpdatedAt,
            "updated_at":        now,
        }),
        Where: clause.Where{Exprs: []clause.Expression{
            clause.Lt{
                Column: clause.Column{Table: clause.CurrentTable, Name: "client_updated_at"},
                Value:  req.ClientUpdatedAt,
            },
        }},
    }).Create(&incoming)

    if result.Error != nil {
        c.JSON(http.StatusInternalServerError, gin.H{"error": result.Error.Error()})
        return
    }

    var current models.ReadingProgress
    if err := config.DB.Where("user_id = ? AND book_id = ?", userID, req.BookID).First(&current).Error; err != nil {
        c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
        return
    }

    if result.RowsAffected == 0 {
        c.JSON(http.StatusConflict, gin.H{
            "message": "Local progress is outdated",
            "current": current,
        })
        return
    }

    if current.ID == incoming.ID {
        c.JSON(http.StatusCreated, current)
        return
    }
    c.JSON(http.StatusOK, current)
}