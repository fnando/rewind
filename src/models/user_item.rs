use anyhow::Result;
use rusqlite::{Connection, OptionalExtension, Row, params};

use super::Invalid;
use crate::time;

/// A user's rating and review of an item, keyed by `Item::rating_key`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UserItem {
    pub id: i64,
    pub user_id: i64,
    pub item_key: String,
    pub rating: Option<i64>,
    pub review: Option<String>,
    pub review_created_at: Option<String>,
    pub review_updated_at: Option<String>,
}

impl UserItem {
    fn from_row(row: &Row) -> rusqlite::Result<Self> {
        Ok(Self {
            id: row.get(0)?,
            user_id: row.get(1)?,
            item_key: row.get(2)?,
            rating: row.get(3)?,
            review: row.get(4)?,
            review_created_at: row.get(5)?,
            review_updated_at: row.get(6)?,
        })
    }

    /// # Errors
    /// On database failure.
    pub fn find(conn: &Connection, user_id: i64, item_key: &str) -> Result<Option<Self>> {
        Ok(conn
            .query_row(
                "SELECT id, user_id, item_key, rating, review, review_created_at, \
                 review_updated_at FROM user_items WHERE user_id = ? AND item_key = ?",
                params![user_id, item_key],
                Self::from_row,
            )
            .optional()?)
    }

    fn ensure(conn: &Connection, user_id: i64, item_key: &str) -> Result<Self> {
        if let Some(existing) = Self::find(conn, user_id, item_key)? {
            return Ok(existing);
        }
        let now = time::format(time::now());
        conn.execute(
            "INSERT INTO user_items (user_id, item_key, created_at, updated_at) \
             VALUES (?, ?, ?, ?)",
            params![user_id, item_key, now, now],
        )?;
        Ok(Self::find(conn, user_id, item_key)?.expect("just created"))
    }

    /// Sets or clears (`None`) the rating.
    ///
    /// # Errors
    /// When the rating isn't 1–5, or on database failure.
    pub fn set_rating(
        conn: &Connection,
        user_id: i64,
        item_key: &str,
        rating: Option<i64>,
    ) -> Result<Self> {
        if rating.is_some_and(|r| !(1..=5).contains(&r)) {
            return Err(Invalid(vec!["rating must be between 1 and 5".into()]).into());
        }
        let row = Self::ensure(conn, user_id, item_key)?;
        conn.execute(
            "UPDATE user_items SET rating = ?, updated_at = ? WHERE id = ?",
            params![rating, time::format(time::now()), row.id],
        )?;
        Ok(Self::find(conn, user_id, item_key)?.expect("exists"))
    }

    /// Sets or clears (blank) the review, keeping its first-written time.
    ///
    /// # Errors
    /// On database failure.
    pub fn set_review(
        conn: &Connection,
        user_id: i64,
        item_key: &str,
        review: &str,
    ) -> Result<Self> {
        let row = Self::ensure(conn, user_id, item_key)?;
        let now = time::format(time::now());
        let review = review.trim();
        if review.is_empty() {
            conn.execute(
                "UPDATE user_items SET review = NULL, review_created_at = NULL, \
                 review_updated_at = NULL, updated_at = ? WHERE id = ?",
                params![now, row.id],
            )?;
        } else {
            conn.execute(
                "UPDATE user_items SET review = ?, \
                 review_created_at = COALESCE(review_created_at, ?), \
                 review_updated_at = ?, updated_at = ? WHERE id = ?",
                params![review, now, now, now, row.id],
            )?;
        }
        Ok(Self::find(conn, user_id, item_key)?.expect("exists"))
    }
}
