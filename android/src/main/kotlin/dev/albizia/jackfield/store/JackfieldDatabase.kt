package dev.albizia.jackfield.store

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase

@Database(entities = [CallEntity::class, EventEntity::class, AdapterState::class, PushTokenEntity::class], version = 1, exportSchema = true)
abstract class JackfieldDatabase : RoomDatabase() {
    abstract fun events(): EventDao
    companion object {
        fun open(context: Context): JackfieldDatabase = Room.databaseBuilder(
            context.applicationContext, JackfieldDatabase::class.java,
            context.noBackupFilesDir.resolve("jackfield-v1.db").absolutePath,
        ).build()
    }
}
