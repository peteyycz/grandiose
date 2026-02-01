const std = @import("std");

pub const ParseResult = struct {
    params: [16]u16,
    len: u8,
};

pub fn parse(str: []const u8) ParseResult {
    var iter = std.mem.splitScalar(u8, str, ';');
    // TODO find a better len for this array, SOMEHOW
    var result: [16]u16 = undefined;
    var counter: u16 = 0;
    while (iter.next()) |entry| {
        var num: u16 = 0;
        for (entry) |value| {
            num = num * 10 + (value - '0'); // ASCII number hack
        }
        result[counter] = num;
        counter += 1;
    }

    return ParseResult{ .params = result, .len = @intCast(counter) };
}

test "should parse string array into numbers" {
    const result = parse("10;54");
    try std.testing.expectEqual(result.len, 2);
    try std.testing.expectEqual(result.params[0], 10);
    try std.testing.expectEqual(result.params[1], 54);
}
