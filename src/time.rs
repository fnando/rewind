//! Time handling: the fixed storage format for instants, the swappable time
//! zone database, and the conversions between UTC and a user's local time.

use std::sync::{Arc, LazyLock};

use arc_swap::ArcSwap;
use jiff::civil::{Date, DateTime};
use jiff::tz::{Disambiguation, TimeZone, TimeZoneDatabase};
use jiff::{Timestamp, Zoned};

/// The zone database in use. Starts as jiff's (system zoneinfo, else the copy
/// compiled into the binary) and is swapped at runtime when a newer tzdata
/// release is downloaded.
static TZDB: LazyLock<ArcSwap<TimeZoneDatabase>> =
    LazyLock::new(|| ArcSwap::from_pointee(jiff::tz::db().clone()));

pub fn set_tzdb(db: TimeZoneDatabase) {
    TZDB.store(Arc::new(db));
}

/// The named zone, or UTC when the name is unknown.
#[must_use]
pub fn zone(name: &str) -> TimeZone {
    TZDB.load().get(name).unwrap_or(TimeZone::UTC)
}

#[must_use]
pub fn is_zone(name: &str) -> bool {
    name == "UTC" || TZDB.load().get(name).is_ok()
}

/// Every zone name the database knows, sorted.
#[must_use]
pub fn zone_names() -> Vec<String> {
    let mut names: Vec<String> = TZDB
        .load()
        .available()
        .map(|name| name.as_str().to_string())
        .filter(|name| !name.starts_with("posix/") && !name.starts_with("right/"))
        .collect();
    names.sort();
    names.dedup();
    names
}

#[must_use]
pub fn now() -> Timestamp {
    Timestamp::now()
}

/// The storage format for instants: UTC RFC 3339 with a fixed six-digit
/// fraction, so stored values sort and compare correctly as text.
#[must_use]
pub fn format(ts: Timestamp) -> String {
    ts.strftime("%Y-%m-%dT%H:%M:%S%.6fZ").to_string()
}

/// Parses a stored or feed instant (any RFC 3339 form).
#[must_use]
pub fn parse(value: &str) -> Option<Timestamp> {
    value.trim().parse().ok()
}

/// The moment `ts` as seen in `zone_name`.
#[must_use]
pub fn local(ts: Timestamp, zone_name: &str) -> Zoned {
    ts.to_zoned(zone(zone_name))
}

#[must_use]
pub fn today(zone_name: &str) -> Date {
    local(now(), zone_name).date()
}

/// Where a play happened on the user's clock, captured once at write so a
/// later time zone change never moves it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalStamp {
    pub date: String,
    pub time: String,
    pub hour: i8,
    /// 1 = Monday … 7 = Sunday.
    pub weekday: i8,
    pub offset_minutes: i32,
    pub timezone: String,
}

impl LocalStamp {
    #[must_use]
    pub fn new(ts: Timestamp, zone_name: &str) -> Self {
        let tz = zone(zone_name);
        let timezone = if tz == TimeZone::UTC && zone_name != "UTC" {
            "UTC".to_string()
        } else {
            zone_name.to_string()
        };
        let zoned = ts.to_zoned(tz);
        Self {
            date: zoned.date().to_string(),
            time: zoned.strftime("%H:%M").to_string(),
            hour: zoned.hour(),
            weekday: zoned.weekday().to_monday_one_offset(),
            offset_minutes: zoned.offset().seconds() / 60,
            timezone,
        }
    }
}

/// The UTC instant for a wall-clock time typed in `zone_name`, from a
/// datetime-local value ("2026-11-09T11:21", seconds optional). `None` when it
/// isn't one. A time skipped by a DST jump rolls forward an hour; one repeated
/// by a DST fall-back reads as the first occurrence.
#[must_use]
pub fn local_to_utc(value: &str, zone_name: &str) -> Option<Timestamp> {
    let value = value.trim().replacen(' ', "T", 1);
    let shape_ok = matches!(value.len(), 16 | 19)
        && value.as_bytes()[4] == b'-'
        && value.as_bytes()[10] == b'T';
    if !shape_ok {
        return None;
    }
    let datetime: DateTime = value.parse().ok()?;
    zone(zone_name)
        .to_ambiguous_zoned(datetime)
        .disambiguate(Disambiguation::Compatible)
        .ok()
        .map(|zoned| zoned.timestamp())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ts(value: &str) -> Timestamp {
        value.parse().unwrap()
    }

    #[test]
    fn formats_with_a_fixed_width() {
        assert_eq!(
            format(ts("2026-11-09T16:42:01Z")),
            "2026-11-09T16:42:01.000000Z"
        );
        assert_eq!(
            format(ts("2026-11-09T16:42:01.5Z")),
            "2026-11-09T16:42:01.500000Z"
        );
    }

    #[test]
    fn local_stamp_uses_the_offset_at_that_instant() {
        // 21:15 PDT (UTC-7) on the 30th is 04:15 UTC on the 31st.
        let stamp = LocalStamp::new(ts("2026-10-31T04:15:00Z"), "America/Los_Angeles");
        assert_eq!(stamp.date, "2026-10-30");
        assert_eq!(stamp.time, "21:15");
        assert_eq!(stamp.hour, 21);
        assert_eq!(stamp.weekday, 5);
        assert_eq!(stamp.offset_minutes, -420);
        assert_eq!(stamp.timezone, "America/Los_Angeles");

        // After the fall-back the same zone is UTC-8.
        let winter = LocalStamp::new(ts("2026-11-09T04:15:00Z"), "America/Los_Angeles");
        assert_eq!(winter.offset_minutes, -480);
        assert_eq!(winter.time, "20:15");
    }

    #[test]
    fn local_stamp_handles_half_hour_offsets() {
        let stamp = LocalStamp::new(ts("2026-11-09T20:00:00Z"), "Asia/Kolkata");
        assert_eq!(stamp.date, "2026-11-10");
        assert_eq!(stamp.time, "01:30");
        assert_eq!(stamp.hour, 1);
        assert_eq!(stamp.offset_minutes, 330);
    }

    #[test]
    fn unknown_zones_read_as_utc() {
        let stamp = LocalStamp::new(ts("2026-11-09T20:00:00Z"), "Mars/Base");
        assert_eq!(stamp.timezone, "UTC");
        assert_eq!(stamp.time, "20:00");
    }

    #[test]
    fn local_to_utc_reads_the_users_zone() {
        assert_eq!(
            local_to_utc("2026-10-30T21:15", "America/Los_Angeles"),
            Some(ts("2026-10-31T04:15:00Z"))
        );
        assert_eq!(
            local_to_utc("2026-10-30T21:15:30", "America/Los_Angeles"),
            Some(ts("2026-10-31T04:15:30Z"))
        );
    }

    #[test]
    fn a_time_skipped_by_dst_rolls_forward() {
        assert_eq!(
            local_to_utc("2026-03-08T02:30", "America/Los_Angeles"),
            Some(ts("2026-03-08T10:30:00Z"))
        );
    }

    #[test]
    fn a_repeated_time_reads_as_the_first() {
        // 01:30 happens twice on 2026-11-01; the first is PDT (UTC-7).
        assert_eq!(
            local_to_utc("2026-11-01T01:30", "America/Los_Angeles"),
            Some(ts("2026-11-01T08:30:00Z"))
        );
    }

    #[test]
    fn local_to_utc_rejects_other_shapes() {
        assert_eq!(local_to_utc("yesterday-ish", "UTC"), None);
        assert_eq!(local_to_utc("2026-02-30T10:00", "UTC"), None);
        assert_eq!(local_to_utc("2026-10-30", "UTC"), None);
    }
}
