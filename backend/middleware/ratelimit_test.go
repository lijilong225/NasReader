package middleware

import (
	"testing"
	"time"
)

func TestLoginRateLimiterLocksAfterMaxFailures(t *testing.T) {
	l := NewLoginRateLimiter(3, time.Minute, time.Minute)

	for i := 0; i < 2; i++ {
		l.RecordFailure("1.2.3.4")
		if ok, _ := l.Allow("1.2.3.4"); !ok {
			t.Fatalf("第 %d 次失败后不应锁定", i+1)
		}
	}

	l.RecordFailure("1.2.3.4")
	ok, retryAfter := l.Allow("1.2.3.4")
	if ok {
		t.Fatal("达到失败上限后应锁定")
	}
	if retryAfter <= 0 || retryAfter > time.Minute {
		t.Fatalf("剩余锁定时间异常: %v", retryAfter)
	}
}

func TestLoginRateLimiterIsolatesKeys(t *testing.T) {
	l := NewLoginRateLimiter(1, time.Minute, time.Minute)
	l.RecordFailure("1.1.1.1")

	if ok, _ := l.Allow("1.1.1.1"); ok {
		t.Fatal("触发上限的 key 应被锁定")
	}
	if ok, _ := l.Allow("2.2.2.2"); !ok {
		t.Fatal("其它 key 不应受影响")
	}
}

func TestLoginRateLimiterResetOnSuccess(t *testing.T) {
	l := NewLoginRateLimiter(2, time.Minute, time.Minute)
	l.RecordFailure("1.2.3.4")
	l.Reset("1.2.3.4")

	// Reset 清空计数，后续应重新累计到上限才锁定
	l.RecordFailure("1.2.3.4")
	if ok, _ := l.Allow("1.2.3.4"); !ok {
		t.Fatal("Reset 后计数应归零")
	}
}

func TestLoginRateLimiterWindowExpiry(t *testing.T) {
	l := NewLoginRateLimiter(2, 20*time.Millisecond, time.Minute)
	l.RecordFailure("1.2.3.4")
	time.Sleep(40 * time.Millisecond)

	// 统计窗口过期后旧失败不再累加，因此这次失败只算第一次
	l.RecordFailure("1.2.3.4")
	if ok, _ := l.Allow("1.2.3.4"); !ok {
		t.Fatal("跨窗口的失败不应累计导致锁定")
	}
}

func TestLoginRateLimiterUnlocksAfterLockout(t *testing.T) {
	l := NewLoginRateLimiter(1, time.Minute, 20*time.Millisecond)
	l.RecordFailure("1.2.3.4")
	if ok, _ := l.Allow("1.2.3.4"); ok {
		t.Fatal("应先进入锁定")
	}

	time.Sleep(40 * time.Millisecond)
	if ok, _ := l.Allow("1.2.3.4"); !ok {
		t.Fatal("锁定期结束后应放行")
	}
}

func TestLoginRateLimiterCleanupRemovesStaleEntries(t *testing.T) {
	l := NewLoginRateLimiter(5, 10*time.Millisecond, 10*time.Millisecond)
	l.RecordFailure("1.2.3.4")
	time.Sleep(30 * time.Millisecond)

	l.cleanup()

	l.mu.Lock()
	remaining := len(l.attempts)
	l.mu.Unlock()
	if remaining != 0 {
		t.Fatalf("过期条目应被回收，剩余 %d 条", remaining)
	}
}
