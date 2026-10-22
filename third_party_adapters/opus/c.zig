// Private third-party ABI. No imported type is exported by root.zig.
pub const api = @cImport({
    @cDefine("DISABLE_FLOAT_API", "1");
    @cInclude("opus_multistream.h");
    @cInclude("ogg/ogg.h");
});
