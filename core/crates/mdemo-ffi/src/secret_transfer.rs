//! 비밀 값의 UniFFI 전송. Swift에서는 기존 Data · String으로 보인다.
//! 입력 직렬화 버퍼와 소유한 평문은 Rust에서 덮고, 소유권을 넘긴 출력 버퍼는
//! 보강한 Swift 바인딩이 해제 직전에 덮는다.
use mdemo_crypto::{Secret, Zeroizing};
use uniffi::{
    deps::anyhow::{bail, Result},
    FfiConverter, MetadataBuffer, RustBuffer,
};

pub struct SecretBytes(pub Secret);
pub struct SecretText(pub Secret);

fn read_bytes(buf: &mut &[u8]) -> Result<Secret> {
    if buf.len() < 4 {
        bail!("바이트 길이 없음");
    }
    let len = i32::from_be_bytes(buf[..4].try_into()?) as usize;
    if len > buf.len() - 4 {
        bail!("바이트 길이 오류");
    }
    let value = Zeroizing::new(buf[4..4 + len].to_vec());
    *buf = &buf[4 + len..];
    Ok(value)
}
fn write_bytes(value: &[u8], buf: &mut Vec<u8>) {
    buf.extend_from_slice(
        &i32::try_from(value.len())
            .expect("전송 길이 초과")
            .to_be_bytes(),
    );
    buf.extend_from_slice(value);
}

// 안전 조건: Data와 같은 길이 + 바이트 형식을 쓰고 RustBuffer의 소유권을 한 번만 회수한다.
unsafe impl FfiConverter<crate::UniFfiTag> for SecretBytes {
    type FfiType = RustBuffer;
    fn lower(obj: Self) -> RustBuffer {
        let mut output = Zeroizing::new(Vec::new());
        Self::write(obj, &mut output);
        RustBuffer::from_vec(std::mem::take(&mut *output))
    }
    fn try_lift(buf: RustBuffer) -> Result<Self> {
        let serialized = Zeroizing::new(buf.destroy_into_vec());
        let mut reader = serialized.as_slice();
        let value = Self::try_read(&mut reader)?;
        if !reader.is_empty() {
            bail!("남은 전송 바이트");
        }
        Ok(value)
    }
    fn write(obj: Self, buf: &mut Vec<u8>) {
        write_bytes(&obj.0, buf);
    }
    fn try_read(buf: &mut &[u8]) -> Result<Self> {
        Ok(Self(read_bytes(buf)?))
    }
    const TYPE_ID_META: MetadataBuffer =
        <Vec<u8> as uniffi::TypeId<crate::UniFfiTag>>::TYPE_ID_META;
}
uniffi::derive_ffi_traits!(local SecretBytes);

// 안전 조건: String과 같은 UTF-8 형식이다. 본문을 String으로 복사해 버리는 중간 단계를 없앤다.
unsafe impl FfiConverter<crate::UniFfiTag> for SecretText {
    type FfiType = RustBuffer;
    fn lower(mut obj: Self) -> RustBuffer {
        RustBuffer::from_vec(std::mem::take(&mut *obj.0))
    }
    fn try_lift(buf: RustBuffer) -> Result<Self> {
        let value = Zeroizing::new(buf.destroy_into_vec());
        std::str::from_utf8(&value)?;
        Ok(Self(value))
    }
    fn write(obj: Self, buf: &mut Vec<u8>) {
        write_bytes(&obj.0, buf);
    }
    fn try_read(buf: &mut &[u8]) -> Result<Self> {
        let value = read_bytes(buf)?;
        std::str::from_utf8(&value)?;
        Ok(Self(value))
    }
    const TYPE_ID_META: MetadataBuffer = <String as FfiConverter<crate::UniFfiTag>>::TYPE_ID_META;
}
uniffi::derive_ffi_traits!(local SecretText);

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn data_and_string_wire_formats_match_and_reject_bad_input() {
        let mut serialized = Vec::new();
        SecretBytes::write(
            SecretBytes(Zeroizing::new(b"Ab12".to_vec())),
            &mut serialized,
        );
        assert_eq!(serialized, b"\0\0\0\x04Ab12");
        let mut reader = serialized.as_slice();
        assert_eq!(&*SecretText::try_read(&mut reader).unwrap().0, b"Ab12");
        assert!(reader.is_empty());
        assert!(SecretBytes::try_read(&mut &b"\xff\xff\xff\xff"[..]).is_err());
        assert!(SecretText::try_read(&mut &b"\0\0\0\x01\xff"[..]).is_err());
    }
}
