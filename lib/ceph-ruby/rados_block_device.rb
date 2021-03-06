module CephRuby
  class RadosBlockDevice
    FEATURE_LAYERING = 1
    FEATURE_STRIPING_V2 = 2
    FEATURE_EXCLUSIVE_LOCK = 4
    FEATURE_OBJECT_MAP = 8

    attr_accessor :pool, :name, :handle

    delegate :cluster, :to => :pool

    def initialize(pool, name)
      self.pool = pool
      self.name = name
      if block_given?
        begin
          yield(self)
        ensure
          close
        end
      end
    end

    def exists?
      log("exists?")
      handle_p = FFI::MemoryPointer.new(:pointer)
      ret = Lib::Rbd.rbd_open(pool.handle, name, handle_p, nil)
      case ret
      when 0
        handle = handle_p.get_pointer(0)
        Lib::Rbd.rbd_close(handle)
        true
      when -Errno::ENOENT::Errno
        false
      else
        raise SystemCallError.new("open of '#{name}' failed", -ret) if ret < 0
      end
    end

    def create(size, features = 0, order = 0)
      log("create size #{size}, features #{features}, order #{order}")
      order_p = FFI::MemoryPointer.new(:int)
      order_p.put_int(0, order)
      ret = Lib::Rbd.rbd_create2(pool.handle, name, size, features, order_p)
      raise SystemCallError.new("creation of '#{name}' failed", -ret) if ret < 0
    end

    def open
      return if open?
      log("open")
      handle_p = FFI::MemoryPointer.new(:pointer)
      ret = Lib::Rbd.rbd_open(pool.handle, name, handle_p, nil)
      raise SystemCallError.new("open of '#{name}' failed", -ret) if ret < 0
      self.handle = handle_p.get_pointer(0)
    end

    def close
      return unless open?
      log("close")
      Lib::Rbd.rbd_close(handle)
      self.handle = nil
    end

    def destroy
      close if open?
      log("destroy")
      ret = Lib::Rbd.rbd_remove(pool.handle, name)
      raise SystemCallError.new("destroy of '#{name}' failed", -ret) if ret < 0
    end

    def rename(new_name)
      close if open?
      log("rename")
      ret = Lib::Rbd.rbd_rename(pool.handle, name, new_name)
      raise SystemCallError.new("rename of '#{name}' failed", -ret) if ret < 0
    end

    def write(offset, data)
      ensure_open
      size = data.bytesize
      log("write offset #{offset}, size #{size}")
      ret = Lib::Rbd.rbd_write(handle, offset, size, data)
      raise SystemCallError.new("write of #{size} bytes to '#{name}' at #{offset} failed", -ret) if ret < 0
      raise Errno::EIO.new("wrote only #{ret} of #{size} bytes to '#{name}' at #{offset}") if ret < size
    end

    def read(offset, size)
      ensure_open
      log("read offset #{offset}, size #{size}")
      data_p = FFI::MemoryPointer.new(:char, size)
      ret = Lib::Rbd.rbd_read(handle, offset, size, data_p)
      raise SystemCallError.new("read of #{size} bytes from '#{name}' at #{offset} failed", -ret) if ret < 0
      data_p.get_bytes(0, ret)
    end

    def stat
      ensure_open
      log("stat")
      stat = Lib::Rbd::StatStruct.new
      ret = Lib::Rbd.rbd_stat(handle, stat, stat.size)
      raise SystemCallError.new("stat of '#{name}' failed", -ret) if ret < 0
      Hash[[:size, :obj_size, :num_objs, :order].map{ |k| [k, stat[k]] }].tap do |hash|
        hash[:block_name_prefix] = stat[:block_name_prefix].to_ptr.read_string
      end
    end

    def size
      ensure_open
      log("size")
      size_p = FFI::MemoryPointer.new(:uint64)
      ret = Lib::Rbd.rbd_get_size(handle, size_p)
      raise SystemCallError.new("size of '#{name}' failed", -ret) if ret < 0
      size_p.read_uint64
    end

    def features
      ensure_open
      log("features")
      features_p = FFI::MemoryPointer.new(:uint64)
      ret = Lib::Rbd.rbd_get_features(handle, features_p)
      raise SystemCallError.new("features of '#{name}' failed", -ret) if ret < 0
      features_p.read_uint64
    end

    def resize(size)
      ensure_open
      log("resize size #{size}")
      ret = Lib::Rbd.rbd_resize(handle, size)
      raise SystemCallError.new("resize of '#{name}' to #{size} failed", -ret) if ret < 0
    end

    def copy_to(dst_name, dst_pool = nil)
      ensure_open
      case dst_pool
      when String
        dst_pool = cluster.pool(dst_pool)
      when nil
        dst_pool = pool
      end
      dst_pool.ensure_open
      log("copy_to #{dst_pool.name}/#{dst_name}")
      ret = Lib::Rbd.rbd_copy(handle, dst_pool.handle, dst_name)
      raise SystemCallError.new("copy of '#{name}' to '#{dst_pool.name}/#{dst_name}' failed", -ret) if ret < 0
    end

    def snapshot_create(name)
      log("snapshot_create #{name}")
      ensure_open
      ret = Lib::Rbd.rbd_snap_create(handle, name)
      raise SystemCallError.new("snapshot create '#{name}' of '#{self.name}' failed", -ret) if ret < 0
    end

    def snapshot_destroy(name)
      log("snapshot_destroy #{name}")
      ensure_open
      ret = Lib::Rbd.rbd_snap_remove(handle, name)
      raise SystemCallError.new("snapshot destroy '#{name}' of '#{self.name}' failed", -ret) if ret < 0
    end

    def snapshot_protect(name)
      log("snapshot_protect #{name}")
      ensure_open
      ret = Lib::Rbd.rbd_snap_protect(handle, name)
      raise SystemCallError.new("snapshot protect '#{name}' of '#{self.name}' failed", -ret) if ret < 0
    end

    def snapshot_unprotect(name)
      log("snapshot_unprotect #{name}")
      ensure_open
      ret = Lib::Rbd.rbd_snap_unprotect(handle, name)
      raise SystemCallError.new("snapshot unprotect '#{name}' of '#{self.name}' failed", -ret) if ret < 0
    end

    def snapshot_activate(name)
      log("snapshot_activate #{name}")
      ensure_open
      ret = Lib::Rbd.rbd_snap_set(handle, name)
      raise SystemCallError.new("activate snapshot '#{name}' of '#{self.name}' failed", -ret) if ret < 0
    end

    def clone(snapshot, dst_name, dst_pool = nil, features = 0, order = 0)
      ensure_open
      case dst_pool
      when String
        dst_pool = cluster.pool(dst_pool)
      when nil
        dst_pool = pool
      end
      dst_pool.ensure_open
      log("clone snapshot #{snapshot} to #{dst_pool.name}/#{dst_name} features #{features} order #{order}")
      order_p = FFI::MemoryPointer.new(:int)
      order_p.put_int(0, order)
      ret = Lib::Rbd.rbd_clone(pool.handle, name, snapshot, dst_pool.handle, dst_name, features, order_p)
      raise SystemCallError.new("clone of '#{name}@#{snapshot}' to '#{dst_pool.name}/#{dst_name}' failed", -ret) if ret < 0
    end

    def flatten
      log("flatten")
      ensure_open
      ret = Lib::Rbd.rbd_flatten(handle)
      raise SystemCallError.new("flatten of '#{name}' failed", -ret) if ret < 0
    end

    def metadata
      log("metadata")
      ensure_open

      keys_size_p   = FFI::MemoryPointer.new(:size_t)
      values_size_p = FFI::MemoryPointer.new(:size_t)

      ret = Lib::Rbd.rbd_metadata_list(handle, '', 0, nil, keys_size_p, nil, values_size_p)

      return {} if ret == 0

      raise SystemCallError.new('Query of metadata size failed') if ret != -Errno::ERANGE::Errno

      keys_p   = FFI::MemoryPointer.new(:char, keys_size_p.get_int(0))
      values_p = FFI::MemoryPointer.new(:char, values_size_p.get_int(0))

      ret = Lib::Rbd.rbd_metadata_list(handle, "", 0, keys_p, keys_size_p, values_p, values_size_p)

      raise SystemCallError.new('Query of metadata failed') if ret < 0

      keys   = keys_p.get_bytes(0, keys_size_p.get_int(0)).split("\0")
      values = values_p.get_bytes(0, values_size_p.get_int(0)).split("\0")

      Hash[keys.zip values]
    end

    def metadata_set(key, value)
      log("metadata_set #{key}")
      ensure_open

      ret = Lib::Rbd.rbd_metadata_set(handle, key, value)
      raise SystemCallError.new('Set of metadata failed') if ret < 0
      nil
    end

    def parent_info
      log("parent_info")
      ensure_open

      size = 8

      parent_poolname_p = nil
      parent_name_p     = nil
      parent_snapname_p = nil

      loop do
        size = size * 2
        break if size > 4096

        parent_poolname_p = FFI::MemoryPointer.new(:char, size)
        parent_name_p     = FFI::MemoryPointer.new(:char, size)
        parent_snapname_p = FFI::MemoryPointer.new(:char, size)

        ret = Lib::Rbd.rbd_get_parent_info(handle,
                                           parent_poolname_p, size,
                                           parent_name_p, size,
                                           parent_snapname_p, size)


        next if ret == -Errno::ERANGE::Errno

        # No parent, return nil
        return nil if ret < 0

        break
      end

      raise SystemCallError.new('Query of parent info size failed') if size > 4096

      {
        pool: parent_poolname_p.get_bytes(0, size).split("\0")[0],
        name: parent_name_p.get_bytes(0, size).split("\0")[0],
        snap: parent_snapname_p.get_bytes(0, size).split("\0")[0]
      }
    end

    # helper methods below

    def open?
      !!handle
    end

    def ensure_open
      return if open?
      open
    end

    def log(message)
      CephRuby.log("rbd image #{pool.name}/#{name} #{message}")
    end
  end
end
