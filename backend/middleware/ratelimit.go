package middleware

import (
	"net/http"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

// LoginRateLimiter 基于内存的失败计数器，用于阻挡登录/注册接口的暴力破解。
// 单实例部署足够；若将来横向扩展需换成 Redis 等共享存储。
type LoginRateLimiter struct {
	mu       sync.Mutex
	attempts map[string]*attemptRecord

	maxFailures int
	window      time.Duration
	lockout     time.Duration
}

type attemptRecord struct {
	failures    int
	firstFailAt time.Time
	lockedUntil time.Time
}

func NewLoginRateLimiter(maxFailures int, window, lockout time.Duration) *LoginRateLimiter {
	return &LoginRateLimiter{
		attempts:    make(map[string]*attemptRecord),
		maxFailures: maxFailures,
		window:      window,
		lockout:     lockout,
	}
}

// Allow 返回该 key 当前是否允许尝试，以及剩余锁定时间。
func (l *LoginRateLimiter) Allow(key string) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()

	rec, ok := l.attempts[key]
	if !ok {
		return true, 0
	}

	now := time.Now()
	if now.Before(rec.lockedUntil) {
		return false, rec.lockedUntil.Sub(now)
	}

	// 统计窗口已过期，重置计数
	if now.Sub(rec.firstFailAt) > l.window {
		delete(l.attempts, key)
	}
	return true, 0
}

func (l *LoginRateLimiter) RecordFailure(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()

	now := time.Now()
	rec, ok := l.attempts[key]
	if !ok || now.Sub(rec.firstFailAt) > l.window {
		l.attempts[key] = &attemptRecord{failures: 1, firstFailAt: now}
		return
	}

	rec.failures++
	if rec.failures >= l.maxFailures {
		rec.lockedUntil = now.Add(l.lockout)
		rec.failures = 0
		rec.firstFailAt = now
	}
}

func (l *LoginRateLimiter) Reset(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.attempts, key)
}

// cleanup 周期性回收过期条目，防止 map 无界增长。
func (l *LoginRateLimiter) cleanup() {
	l.mu.Lock()
	defer l.mu.Unlock()

	now := time.Now()
	for key, rec := range l.attempts {
		if now.After(rec.lockedUntil) && now.Sub(rec.firstFailAt) > l.window {
			delete(l.attempts, key)
		}
	}
}

// StartCleanup 启动后台清理协程。
func (l *LoginRateLimiter) StartCleanup(interval time.Duration) {
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for range ticker.C {
			l.cleanup()
		}
	}()
}

// AuthRateLimit 在进入业务处理前拦截被锁定的客户端 IP。
func AuthRateLimit(limiter *LoginRateLimiter) gin.HandlerFunc {
	return func(c *gin.Context) {
		if ok, retryAfter := limiter.Allow(c.ClientIP()); !ok {
			c.JSON(http.StatusTooManyRequests, gin.H{
				"error":       "尝试次数过多，请稍后再试",
				"retry_after": int(retryAfter.Seconds()) + 1,
			})
			c.Abort()
			return
		}
		c.Next()
	}
}
