package dev.albizia.jackfield.store

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

@Database(entities = [CallEntity::class, EventEntity::class, AdapterState::class, PushTokenEntity::class], version = 2, exportSchema = true)
abstract class JackfieldDatabase : RoomDatabase() {
    abstract fun events(): EventDao
    companion object {
        val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE adapter_state ADD COLUMN rejectedAuthFingerprint TEXT")
            }
        }
        fun open(context: Context): JackfieldDatabase = Room.databaseBuilder(
            context.applicationContext, JackfieldDatabase::class.java,
            context.noBackupFilesDir.resolve("jackfield-v1.db").absolutePath,
        ).addMigrations(MIGRATION_1_2).build()
    }
}
