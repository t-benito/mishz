const math = @import("yazml");

pub fn main() void {
    const eye = math.Vec3f.init(2.0, 0.0, 2.0);
    const target = math.Vec3f.init(5.0, 0.0, 5.0);

    const projection = math.Mat4f.lookAt(
        eye,
        target,
        math.Vec3f.UP,
    );

    _ = projection;
}
