## Re-exports Raylib alongside converters from standard Nim and vmath types so game code
## doesn't need manual float32/int32/Vector2/cdecl conversions.
import pkg/vmath
import pkg/raylib except Vec2, Vec3, Vec4
export raylib except Vec2, Vec3, Vec4

converter toFloat32*(value: float): float32 =
  float32(value)

converter toInt32*(value: int): int32 =
  int32(value)

converter toRaylibVector2*(vec: Vec2): Vector2 =
  Vector2(x: vec.x, y: vec.y)

converter toClosure*[I, T](fn: proc(arg: I): T {.cdecl.}): proc(arg: I): T =
  proc(arg: I): T = fn(arg)
