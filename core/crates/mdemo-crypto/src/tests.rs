use super::*;
use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};

// 해제되는 블록의 내용을 들여다보는 시험용 할당기. 감시하는 크기(아래 WATCH)의 블록이
// 0이 아닌 채로 해제되면 그 횟수를 센다. 해제 직전의 메모리는 읽어도 안전하다.
const WATCH: [usize; 3] = [7777, 4099, 3001];
static FREED: [AtomicUsize; 3] = [AtomicUsize::new(0), AtomicUsize::new(0), AtomicUsize::new(0)];
static DIRTY: [AtomicUsize; 3] = [AtomicUsize::new(0), AtomicUsize::new(0), AtomicUsize::new(0)];

struct Watcher;
unsafe impl GlobalAlloc for Watcher {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        System.alloc(layout)
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        if let Some(slot) = WATCH.iter().position(|size| *size == layout.size()) {
            FREED[slot].fetch_add(1, Ordering::SeqCst);
            if std::slice::from_raw_parts(ptr, layout.size()).iter().any(|b| *b != 0) {
                DIRTY[slot].fetch_add(1, Ordering::SeqCst);
            }
        }
        System.dealloc(ptr, layout)
    }
}
#[global_allocator]
static ALLOCATOR: Watcher = Watcher;

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[test]
fn password_rules_count_utf8_bytes() {
    for good in ["Ab12", "abcdef", "ZZ99zz", "1234"] {
        assert!(valid_password(good.as_bytes()), "{good}");
    }
    // 3바이트, 7바이트, 기호, 한글(한 글자가 3바이트라 "가나"는 6바이트여도 글자 종류가 틀림)
    for bad in ["abc", "abcdefg", "ab c1", "ab-12", "가나", "ab12\n"] {
        assert!(!valid_password(bad.as_bytes()), "{bad}");
    }
}

#[test]
fn filtered_password_matches_swift_case() {
    assert_eq!(filtered_password("가a B!c12한345".as_bytes()).as_slice(), b"aBc123");
    assert_eq!(filtered_password(b"").as_slice(), b"");
}

#[test]
fn constant_time_equal_matches_swift_cases() {
    assert!(!constant_time_equal(b"Ab12", b"ab12"));
    assert!(constant_time_equal(b"Ab12", b"Ab12"));
    assert!(!constant_time_equal(b"123456A", b"123456B"));
    assert!(!constant_time_equal(b"123456", b"123456A"));
    // 0바이트로 채워도 길이 차이가 남는다.
    assert!(!constant_time_equal(b"ab", b"ab\0"));
    assert!(constant_time_equal(b"", b""));
}

#[test]
fn derive_checks_inputs_before_working() {
    let salt = [1u8; 16];
    assert_eq!(derive(b"abc", &salt, 2_000_000), Err(LockError::Damaged));
    assert_eq!(derive(b"abcd", &salt[..15], 2_000_000), Err(LockError::Damaged));
    assert_eq!(derive(b"abcd", &salt, 1_999_999), Err(LockError::Damaged));
    assert_eq!(derive(b"abcd", &salt, 20_000_001), Err(LockError::Damaged));
    assert_eq!(derive(b"abcd", &salt, -5), Err(LockError::Damaged));
}

#[test]
fn pbkdf2_matches_rfc_7914_vector_and_derive_is_deterministic() {
    // RFC 7914 5절의 PBKDF2-HMAC-SHA-256 (P="passwd", S="salt", c=1, dkLen=64) 앞 32바이트.
    let mut out = [0u8; 32];
    super::crypto::run_pbkdf2_for_tests(b"passwd", b"salt", 1, &mut out);
    assert_eq!(hex(&out), "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc");
    let a = derive(b"Ab12", &[7u8; 16], 2_000_000).unwrap();
    let b = derive(b"Ab12", &[7u8; 16], 2_000_000).unwrap();
    let c = derive(b"Ab13", &[7u8; 16], 2_000_000).unwrap();
    assert_eq!(a.len(), 32);
    assert_eq!(a, b);
    assert_ne!(a, c);
}

#[test]
fn calibrated_iterations_stay_in_range() {
    let n = calibrated_iterations();
    assert!((MINIMUM_ITERATIONS..=MAXIMUM_ITERATIONS).contains(&n), "{n}");
}

#[test]
fn seal_open_round_trip_and_layout() {
    let key = random(32).unwrap();
    let sealed = seal(b"hello", &key, "ID/body").unwrap();
    assert_eq!(sealed.len(), NONCE_LENGTH + 5 + TAG_LENGTH);
    assert_eq!(open(&sealed, &key, "ID/body").unwrap().as_slice(), b"hello");
    // 같은 평문도 nonce가 무작위라 매번 다르다.
    assert_ne!(sealed, seal(b"hello", &key, "ID/body").unwrap());
    // 빈 평문도 28바이트가 된다 (Swift 저장소가 요구하는 최소 길이).
    assert_eq!(seal(b"", &key, "c").unwrap().len(), 28);
}

#[test]
fn open_rejects_wrong_context_key_tamper_and_short_input() {
    let key = random(32).unwrap();
    let other = random(32).unwrap();
    let sealed = seal(b"hello", &key, "ID/body").unwrap();
    assert_eq!(open(&sealed, &key, "ID/attachment/a").unwrap_err(), LockError::Authentication);
    assert_eq!(open(&sealed, &other, "ID/body").unwrap_err(), LockError::Authentication);
    for index in [0, NONCE_LENGTH, sealed.len() - 1] {
        let mut broken = sealed.clone();
        broken[index] ^= 1;
        assert_eq!(open(&broken, &key, "ID/body").unwrap_err(), LockError::Authentication);
    }
    assert_eq!(open(&sealed[..27], &key, "ID/body").unwrap_err(), LockError::IncorrectSize);
    assert_eq!(seal(b"x", &key[..31], "c").unwrap_err(), LockError::Locked);
    assert_eq!(open(&sealed, &[], "ID/body").unwrap_err(), LockError::Locked);
}

#[test]
fn session_contexts_and_wrapping() {
    let key = random(32).unwrap();
    let session = MemoLockSession::new("ID1", key.clone());
    let body = session.seal(b"body", None).unwrap();
    let attachment = session.seal(b"img", Some("a.png")).unwrap();
    assert_eq!(session.open(&body, None).unwrap().as_slice(), b"body");
    assert_eq!(session.open(&attachment, Some("a.png")).unwrap().as_slice(), b"img");
    // context가 이름마다 다르다.
    assert_eq!(session.open(&attachment, Some("b.png")).unwrap_err(), LockError::Authentication);
    assert_eq!(session.open(&attachment, None).unwrap_err(), LockError::Authentication);
    // 직접 context 문자열로도 열린다 (Swift와 같은 규칙).
    assert_eq!(open(&body, &key, "ID1/body").unwrap().as_slice(), b"body");
    assert_eq!(open(&attachment, &key, "ID1/attachment/a.png").unwrap().as_slice(), b"img");
    let salt = [3u8; 16];
    let wrapped = session.wrapped(b"Ab12", &salt, 2_000_000).unwrap();
    let kek = derive(b"Ab12", &salt, 2_000_000).unwrap();
    assert_eq!(open(&wrapped, &kek, "ID1/key").unwrap(), key);
    assert_eq!(session.wrapped(b"ab", &salt, 2_000_000).unwrap_err(), LockError::Damaged);
    session.clear();
    assert_eq!(session.seal(b"x", None).unwrap_err(), LockError::Locked);
    assert_eq!(session.open(&body, None).unwrap_err(), LockError::Locked);
    assert_eq!(session.wrapped(b"Ab12", &salt, 2_000_000).unwrap_err(), LockError::Locked);
}

#[test]
fn session_clear_zeroes_the_key_buffer() {
    let session = MemoLockSession::new("ID1", random(32).unwrap());
    let (ptr, capacity) = session.key_buffer();
    assert!(capacity >= 32);
    // 비우기 전에는 열쇠가 들어 있다(32바이트가 전부 0일 확률은 무시한다).
    assert!(unsafe { std::slice::from_raw_parts(ptr, 32) }.iter().any(|b| *b != 0));
    session.clear();
    // 버퍼는 아직 세션이 들고 있으므로 읽어도 안전하다. 용량 전체가 0이어야 한다.
    assert!(unsafe { std::slice::from_raw_parts(ptr, capacity) }.iter().all(|b| *b == 0));
}

#[test]
fn secret_buffers_are_zero_when_freed() {
    // 1) Zeroizing 자체: 감시 크기의 버퍼를 만들고 떨어뜨린다.
    {
        let mut buffer: Secret = Zeroizing::new(vec![0xAB; 7777]);
        assert_eq!(buffer.capacity(), 7777);
        buffer[0] = 0xCD;
    }
    assert_eq!(FREED[0].load(Ordering::SeqCst), 1);
    assert_eq!(DIRTY[0].load(Ordering::SeqCst), 0);

    // 2) 일부러 0으로 덮지 않은 보통 Vec는 감시기가 잡아낸다(감시기가 실제로 동작하는지 확인).
    drop(vec![0xABu8; 4099]);
    assert_eq!(FREED[1].load(Ordering::SeqCst), 1);
    assert_eq!(DIRTY[1].load(Ordering::SeqCst), 1);

    // 3) open이 돌려준 평문 버퍼(길이 3001): 열고 내용을 확인한 뒤 떨어뜨리면 0으로 해제된다.
    //    열기 도중 만든 같은 크기의 다른 임시 버퍼가 있었다면 FREED가 2 이상이 되거나 DIRTY가 올라간다.
    let key = random(32).unwrap();
    let plain = vec![0x5Au8; 3001];
    let sealed = seal(&plain, &key, "ID/body").unwrap();
    let opened = open(&sealed, &key, "ID/body").unwrap();
    assert_eq!(opened.as_slice(), plain.as_slice());
    drop(opened);
    // 평문 `plain`(보통 Vec)도 같은 크기라 함께 센다: 아래에서 지운다.
    let before = (FREED[2].load(Ordering::SeqCst), DIRTY[2].load(Ordering::SeqCst));
    assert_eq!(before, (1, 0), "open 결과가 0이 아닌 채 해제되었거나 같은 크기 임시 버퍼가 남았다");
    drop(plain);
    assert_eq!(FREED[2].load(Ordering::SeqCst), 2);
    assert_eq!(DIRTY[2].load(Ordering::SeqCst), 1); // 호출자가 들고 있던 보통 Vec만 더럽다
}

#[test]
fn key_store_contract_matches_swift_keychain() {
    let store = MemoryKeyStore::default();
    assert_eq!(store.read_key("A").unwrap(), None);
    assert_eq!(store.read_failures("A").unwrap(), 0);
    store.write_key("A", b"wrapped").unwrap();
    store.write_failures("A", 3).unwrap();
    assert_eq!(store.read_key("A").unwrap().as_deref(), Some(&b"wrapped"[..]));
    assert_eq!(store.read_failures("A").unwrap(), 3);
    // 횟수는 글자 그대로("3") 저장된다.
    assert_eq!(store.snapshot().1["A"], b"3");
    store.delete("A").unwrap();
    assert_eq!(store.read_key("A").unwrap(), None);
    assert_eq!(store.read_failures("A").unwrap(), 0);
    // 없는 항목을 지워도 성공.
    store.delete("A").unwrap();
    for bad in [&b"x"[..], b"-1", b"", b"1.5", &[0xff, 0xfe]] {
        store.write_raw_failures("B", bad);
        assert_eq!(store.read_failures("B"), Err(LockError::Damaged), "{bad:?}");
    }
    for ok in [&b"0"[..], b"+7", b"-0", b"12"] {
        store.write_raw_failures("B", ok);
        assert!(store.read_failures("B").is_ok(), "{ok:?}");
    }
}
