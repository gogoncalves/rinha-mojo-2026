"""
Minimal RFC3339 timestamp parser + epoch utils.
Replicates Zig v31 time.zig exactly.

Format expected: "YYYY-MM-DDTHH:MM:SS..." (Z/offset ignored).
"""

from std.memory import UnsafePointer


struct Stamp(TrivialRegisterPassable):
    var year: Int32
    var month: UInt32
    var day: UInt32
    var hour: UInt32
    var minute: UInt32
    var second: UInt32

    def __init__(
        out self,
        year: Int32,
        month: UInt32,
        day: UInt32,
        hour: UInt32,
        minute: UInt32,
        second: UInt32,
    ):
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second


@always_inline
def d(c: UInt8) -> UInt32:
    return UInt32(Int(c) - Int(ord("0")))


@always_inline
def di(c: UInt8) -> Int32:
    return Int32(Int(c) - Int(ord("0")))


def parse_ts(s: UnsafePointer[UInt8, origin=MutExternalOrigin]) -> Stamp:
    """Parse 19+ chars starting at `s`."""
    var year = di(s[0]) * 1000 + di(s[1]) * 100 + di(s[2]) * 10 + di(s[3])
    var month = d(s[5]) * 10 + d(s[6])
    var day = d(s[8]) * 10 + d(s[9])
    var hour = d(s[11]) * 10 + d(s[12])
    var minute = d(s[14]) * 10 + d(s[15])
    var second = d(s[17]) * 10 + d(s[18])
    return Stamp(year, month, day, hour, minute, second)


def day_of_week(year: Int32, month: UInt32, day: UInt32) -> UInt32:
    var ti: Int32 = 0
    var m = Int(month)
    if m == 1:
        ti = 0
    elif m == 2:
        ti = 3
    elif m == 3:
        ti = 2
    elif m == 4:
        ti = 5
    elif m == 5:
        ti = 0
    elif m == 6:
        ti = 3
    elif m == 7:
        ti = 5
    elif m == 8:
        ti = 1
    elif m == 9:
        ti = 4
    elif m == 10:
        ti = 6
    elif m == 11:
        ti = 2
    elif m == 12:
        ti = 4

    var y = year
    if month < 3:
        y = y - 1
    var raw: Int32 = (
        y + (y // 4) - (y // 100) + (y // 400) + ti + Int32(Int(day))
    ) % 7
    var s_: UInt32 = UInt32(Int((raw + 7) % 7))
    return (s_ + 6) % 7


def days_since_epoch(year: Int32, month: UInt32, day: UInt32) -> Int64:
    var y: Int64 = Int64(Int(year))
    if month <= 2:
        y = y - 1
    var era: Int64
    if y >= 0:
        era = y // 400
    else:
        era = (y - 399) // 400
    var yoe: Int64 = y - era * 400
    var mm: Int64 = Int64(Int(month))
    var m_shift: Int64 = mm - 3 if mm > 2 else mm + 9
    var doy: Int64 = (153 * m_shift + 2) // 5 + Int64(Int(day)) - 1
    var doe: Int64 = yoe * 365 + (yoe // 4) - (yoe // 100) + doy
    return era * 146097 + doe - 719468


def epoch_seconds(s: Stamp) -> Int64:
    return (
        days_since_epoch(s.year, s.month, s.day) * 86400
        + Int64(Int(s.hour)) * 3600
        + Int64(Int(s.minute)) * 60
        + Int64(Int(s.second))
    )
