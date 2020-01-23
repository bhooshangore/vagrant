require "log4r"
require "vagrant/util/numeric"
require "vagrant/util/experimental"

module VagrantPlugins
  module ProviderVirtualBox
    module Cap
      module ConfigureDisks
        LOGGER = Log4r::Logger.new("vagrant::plugins::virtualbox::configure_disks")

        # The max amount of disks that can be attached to a single device in a controller
        MAX_DISK_NUMBER = 30.freeze

        # @param [Vagrant::Machine] machine
        # @param [VagrantPlugins::Kernel_V2::VagrantConfigDisk] defined_disks
        # @return [Hash] configured_disks - A hash of all the current configured disks
        def self.configure_disks(machine, defined_disks)
          return {} if defined_disks.empty?

          return {} if !Vagrant::Util::Experimental.feature_enabled?("virtualbox_disk_hdd")

          if defined_disks.size > MAX_DISK_NUMBER
            # you can only attach up to 30 disks per controller, INCLUDING the primary disk
            raise Vagrant::Errors::VirtualBoxDisksDefinedExceedLimit
          end

          machine.ui.info("Configuring storage mediums...")

          current_disks = machine.provider.driver.list_hdds

          configured_disks = {disk: [], floppy: [], dvd: []}

          defined_disks.each do |disk|
            if disk.type == :disk
              disk_data = handle_configure_disk(machine, disk, current_disks)
              configured_disks[:disk] << disk_data unless disk_data.empty?
            elsif disk.type == :floppy
              # TODO: Write me
              machine.ui.warn("Floppy disk configuration not yet supported. Skipping disk #{disk.name}...")
            elsif disk.type == :dvd
              # TODO: Write me
              machine.ui.warn("DVD disk configuration not yet supported. Skipping disk #{disk.name}...")
            end
          end

          return configured_disks
        end

        protected

        # @param [Vagrant::Machine] machine - the current machine
        # @param [Config::Disk] disk - the current disk to configure
        # @param [Array] all_disks - A list of all currently defined disks in VirtualBox
        # @return [Hash] current_disk - Returns the current disk. Returns nil if it doesn't exist
        def self.get_current_disk(machine, disk, all_disks)
          current_disk = nil
          if disk.primary
            # Ensure we grab the proper primary disk
            # We can't rely on the order of `all_disks`, as they will not
            # always come in port order, but primary is always Port 0 Device 0.
            vm_info = machine.provider.driver.show_vm_info
            primary_uuid = vm_info["SATA Controller-ImageUUID-0-0"]

            current_disk = all_disks.select { |d| d["UUID"] == primary_uuid }.first
          else
            current_disk = all_disks.select { |d| d["Disk Name"] == disk.name}.first
          end

          return current_disk
        end

        # Handles all disk configs of type `:disk`
        #
        # @param [Vagrant::Machine] machine - the current machine
        # @param [Config::Disk] disk - the current disk to configure
        # @param [Array] all_disks - A list of all currently defined disks in VirtualBox
        # @return [Hash] - disk_metadata
        def self.handle_configure_disk(machine, disk, all_disks)
          disk_metadata = {}

          # Grab the existing configured disk, if it exists
          current_disk = get_current_disk(machine, disk, all_disks)

          # Configure current disk
          if !current_disk
            # create new disk and attach
            disk_metadata = create_disk(machine, disk)
          elsif compare_disk_state(machine, disk, current_disk)
            disk_metadata = resize_disk(machine, disk, current_disk)
          else
            # TODO: What if it needs to be resized?

            vm_info = machine.provider.driver.show_vm_info
            disk_info = get_port_and_device(vm_info, current_disk)
            if disk_info.empty?
              LOGGER.warn("Disk '#{disk.name}' is not connected to guest '#{machine.name}', Vagrant will attempt to connect disk to guest")
              dsk_info = get_next_port(machine)
              machine.provider.driver.attach_disk(dsk_info[:port],
                                                  dsk_info[:device],
                                                  current_disk["Location"])
            else
              LOGGER.info("No further configuration required for disk '#{disk.name}'")
            end

            disk_metadata = {uuid: current_disk["UUID"], name: disk.name}
          end

          return disk_metadata
        end

        # Check to see if current disk is configured based on defined_disks
        #
        # @param [Kernel_V2::VagrantConfigDisk] disk_config
        # @param [Hash] defined_disk
        # @return [Boolean]
        def self.compare_disk_state(machine, disk_config, defined_disk)
          requested_disk_size = Vagrant::Util::Numeric.bytes_to_megabytes(disk_config.size)
          defined_disk_size = defined_disk["Capacity"].split(" ").first.to_f

          if defined_disk_size > requested_disk_size
            machine.ui.warn("VirtualBox does not support shrinking disk size. Cannot shrink '#{disk_config.name}' disks size")
            return false
          elsif defined_disk_size < requested_disk_size
            return true
          else
            return false
          end
        end

        # Creates and attaches a disk to a machine
        #
        # @param [Vagrant::Machine] machine
        # @param [Kernel_V2::VagrantConfigDisk] disk_config
        def self.create_disk(machine, disk_config)
          machine.ui.detail("Disk '#{disk_config.name}' not found in guest. Creating and attaching disk to guest...")
          disk_provider_config = disk_config.provider_config[:virtualbox] if disk_config.provider_config

          guest_info = machine.provider.driver.show_vm_info
          guest_folder = File.dirname(guest_info["CfgFile"])

          disk_ext = disk_config.disk_ext
          disk_file = File.join(guest_folder, disk_config.name) + ".#{disk_ext}"

          LOGGER.info("Attempting to create a new disk file '#{disk_file}' of size '#{disk_config.size}' bytes")

          disk_var = machine.provider.driver.create_disk(disk_file, disk_config.size, disk_ext.upcase)
          disk_metadata = {uuid: disk_var.split(':').last.strip, name: disk_config.name}

          dsk_controller_info = get_next_port(machine)
          machine.provider.driver.attach_disk(dsk_controller_info[:port], dsk_controller_info[:device], disk_file)

          disk_metadata
        end

        # Finds the next available port
        #
        # SATA Controller-ImageUUID-0-0 (sub out ImageUUID)
        # - Controller: SATA Controller
        # - Port: 0
        # - Device: 0
        #
        # Note: Virtualbox returns the string above with the port and device info
        #  disk_info = key.split("-")
        #  port = disk_info[2]
        #  device = disk_info[3]
        #
        # @param [Vagrant::Machine] machine
        # @return [Hash] dsk_info - The next available port and device on a given controller
        def self.get_next_port(machine)
          vm_info = machine.provider.driver.show_vm_info
          dsk_info = {device: "0", port: "0"}

          disk_images = vm_info.select { |v| v.include?("ImageUUID") && v.include?("SATA Controller") }
          used_ports = disk_images.keys.map { |k| k.split('-') }.map {|v| v[2].to_i}
          next_available_port = ((0..(MAX_DISK_NUMBER-1)).to_a - used_ports).first

          dsk_info[:port] = next_available_port.to_s
          if dsk_info[:port] == ""
            # This likely only occurs if additional disks have been added outside of Vagrant configuration
            LOGGER.warn("There are no more available ports to attach disks to for the SATA Controller. Clear up some space on the SATA controller to attach new disks.")
          end

          dsk_info
        end

        # Looks up a defined_disk for a guests information from virtualbox. If
        # no matching UUID is found, it returns an empty hash.
        #
        # @param [Hash] vm_info - Guest info from show_vm_info
        # @param [Hash] defined_disk - A specific disk with info from list_hdd
        # @return [Hash] disk - A hash with `port` and `device` keys found from a matching UUID in vm_info
        def self.get_port_and_device(vm_info, defined_disk)
          disk = {}
          disk_info_key = vm_info.key(defined_disk["UUID"])
          return disk if !disk_info_key

          disk_info = disk_info_key.split("-")

          disk[:port] = disk_info[2]
          disk[:device] = disk_info[3]

          return disk
        end

        def self.resize_disk(machine, disk_config, defined_disk)
          machine.ui.detail("Disk '#{disk_config.name}' needs to be resized. Resizing disk...", prefix: true)

          if defined_disk["Storage format"] == "VMDK"
            LOGGER.warn("Disk type VMDK cannot be resized in VirtualBox. Vagrant will convert disk to VDI format to resize first, and then convert resized disk back to VMDK format")
            # grab disk to be resized port and device number
            vm_info = machine.provider.driver.show_vm_info
            disk_info = get_port_and_device(vm_info, defined_disk)

            # clone disk to vdi formatted disk
            vdi_disk_file = vmdk_to_vdi(machine.provider.driver, defined_disk["Location"])
            # resize vdi
            machine.provider.driver.resize_disk(vdi_disk_file, disk_config.size.to_i)

            # remove and close original volume
            machine.provider.driver.remove_disk(disk_info[:port], disk_info[:device])
            machine.provider.driver.close_medium(defined_disk["UUID"])

            # clone back to original vmdk format and attach resized disk
            vmdk_disk_file = vdi_to_vmdk(machine.provider.driver, vdi_disk_file)
            machine.provider.driver.attach_disk(disk_info[:port], disk_info[:device], vmdk_disk_file, "hdd")

            # close cloned volume format
            machine.provider.driver.close_medium(vdi_disk_file)

            # Get new updated disk UUID for vagrant disk_meta file
            new_disk_info = machine.provider.driver.list_hdds.select { |h| h["Location"] == defined_disk["Location"] }.first
            defined_disk = new_disk_info

            # TODO: If any of the above steps fail, display a useful error message
            # telling the user how to recover
            #
            # Vagrant could also have a "rescue" here where in the case of failure, it simply
            # reattaches the original disk
          else
            machine.provider.driver.resize_disk(defined_disk["Location"], disk_config.size.to_i)
          end

          disk_metadata = {uuid: defined_disk["UUID"], name: disk_config.name}
          return disk_metadata
        end

        # TODO: Maybe these should be virtualbox driver methods?

        # @param [VagrantPlugins::VirtualboxProvider::Driver] driver
        # @param [String] defined_disk_path
        # @return [String] destination - The cloned disk
        def self.vmdk_to_vdi(driver, defined_disk_path)
          LOGGER.warn("Converting disk '#{defined_disk_path}' from 'vmdk' to 'vdi' format")
          source = defined_disk_path
          destination = File.join(File.dirname(source), File.basename(source, ".*")) + ".vdi"

          driver.clone_disk(source, destination, 'VDI')

          destination
        end

        # @param [VagrantPlugins::VirtualboxProvider::Driver] driver
        # @param [String] defined_disk_path
        # @return [String] destination - The cloned disk
        def self.vdi_to_vmdk(driver, defined_disk_path)
          LOGGER.warn("Converting disk '#{defined_disk_path}' from 'vdi' to 'vmdk' format")
          source = defined_disk_path
          destination = File.join(File.dirname(source), File.basename(source, ".*")) + ".vmdk"

          driver.clone_disk(source, destination, 'VMDK')

          destination
        end
      end
    end
  end
end
