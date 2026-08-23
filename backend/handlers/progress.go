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
)

type SyncProgressRequest struct {
	BookID          string  `json:"book_id" binding:"required"`
	Progress        float64 `json:"progress" binding:"min=0,max=1"`
	Locator         string  `json:"locator" binding:"required"` // 序列化的定位点数据
	DeviceID        string  `json:"device_id" binding:"required"`
	DeviceName      string  `json:"device_name"`
	ClientUpdatedAt int64   `json:"client_updated_at" binding:"required"` // 毫秒时间戳
}

// GetProgress 获取单本书的阅读进度
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

	var existing models.ReadingProgress
	err := config.DB.Where("user_id = ? AND book_id = ?", userID, req.BookID).First(&existing).Error

	if err != nil && err != gorm.ErrRecordNotFound {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	// 记录已存在时，对比时间戳（Last Write Wins）
	if err == nil {
		if req.ClientUpdatedAt <= existing.ClientUpdatedAt {
			// 客户端时间戳旧于或等于服务端现有数据，拒绝覆盖并返回服务端最新数据
			c.JSON(http.StatusConflict, gin.H{
				"message": "Local progress is outdated",
				"current": existing,
			})
			return
		}

		// 更新现有记录
		existing.Progress = req.Progress
		existing.Locator = req.Locator
		existing.DeviceID = req.DeviceID
		existing.DeviceName = req.DeviceName
		existing.ClientUpdatedAt = req.ClientUpdatedAt
		existing.UpdatedAt = time.Now()

		if err := config.DB.Save(&existing).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to update progress"})
			return
		}
		c.JSON(http.StatusOK, existing)
		return
	}

	// 记录不存在，新增记录
	randomBytes := make([]byte, 16)
	_, _ = rand.Read(randomBytes)
	progressID := hex.EncodeToString(randomBytes)

	newProgress := models.ReadingProgress{
		ID:              progressID,
		UserID:          userID,
		BookID:          req.BookID,
		Progress:        req.Progress,
		Locator:         req.Locator,
		DeviceID:        req.DeviceID,
		DeviceName:      req.DeviceName,
		ClientUpdatedAt: req.ClientUpdatedAt,
		UpdatedAt:       time.Now(),
	}

	if err := config.DB.Create(&newProgress).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to create progress"})
		return
	}

	c.JSON(http.StatusCreated, newProgress)
}