#--
# This file is part of Sonic Pi: http://sonic-pi.net
# Full project source: https://github.com/samaaron/sonic-pi
# License: https://github.com/samaaron/sonic-pi/blob/master/LICENSE.md
#
# Copyright 2013, 2014 by Sam Aaron (http://sam.aaron.name).
# All rights reserved.
#
# Permission is granted for use, copying, modification, distribution,
# and distribution of modified versions of this work as long as this
# notice is included.
#++
require_relative 'docsystem'

module SonicPi
  module SpiderAPI

    include SonicPi::DocSystem

    doc name:           :define,
        doc:            "Define a function",
        args:           [[:name, :symbol]],
        opts:          nil,
        accepts_block: true,
        examples:       []
    def define(name, &block)
      raise "define must be called with a code block" unless block
      @user_methods.send(:define_method, name, &block)
    end

    doc name:           :on_keypress,
        doc:            "",
        args:           [],
        opts:           nil,
        accepts_block:  true,
        examples:       [],
        hide:           true
    def on_keypress(&block)
      @keypress_handlers[:foo] = block
    end

    doc name:          :print,
        doc:           "",
        args:          [[:output, :string]],
        opts:          nil,
        accepts_block: false,
        examples:      []
    def print(output)
      __message output
    end

    doc name:           :puts,
        doc:            "",
        args:           [[:output, :string]],
        opts:           nil,
        accepts_block:  false,
        examples:       []
    def puts(output)
      __message output
    end

    doc name:           :rand,
        doc:            "",
        args:           [],
        opts:           {:min => 0.0, :max => 1.0},
        accepts_block:  false,
        examples:       []
    def rand(*opts)
      args_h = resolve_synth_opts_hash_or_array(opts)
      min = args_h[:min] || 0.0
      max = args_h[:min] || 1.0

      range = (min - max).abs
      r = @random_generator.rand(range.to_f)
      smallest = [min, max].min
      r + smallest
    end

    doc name:           :rrand,
        args:           [[:min, :number], [:max, :number]],
        opts:           nil,
        accepts_block:  false,
        doc:            "",
        examples:      []
    def rrand(min, max)
      range = (min - max).abs
      r = @random_generator.rand(range.to_f)
      smallest = [min, max].min
      r + smallest
    end

    doc name:           :rrand_i,
        args:           [[:min, :number], [:max, :number]],
        opts:           nil,
        accepts_block: false,
        doc:            "",
        examples:       []
    def rrand_i(min, max)
      range = (limit - limit2).abs
      r = @random_generator.rand(range.to_i + 1)
      smallest = [limit, limit2].min
      r + smallest
    end

    doc name:           :choose,
        args:           [[:list, :array]],
        opts:           nil,
        accepts_block:  false,
        doc:            "",
        examples:       []
    def choose(list)
      list.to_a.choose
    end

    doc name:           :use_bpm,
        doc:            "",
        args:           [[:bpm, :number]],
        opts:           nil,
        accepts_block:  false,
        examples:       []
    def use_bpm(bpm, &block)
      raise "use_bpm does not work with a block. Perhaps you meant with_bpm" if block
      sleep_mul = 60.0 / bpm
      Thread.current.thread_variable_set(:sonic_pi_spider_sleep_mul, sleep_mul)
    end

    doc name:           :with_bpm,
        doc:            "",
        args:           [],
        opts:           nil,
        accepts_block:  true,
        examples:       []
    def with_bpm(bpm, &block)
      raise "with_bpm must be called with a block. Perhaps you meant use_bpm" unless block
      current_mul = Thread.current.thread_variable_get(:sonic_pi_spider_sleep_mul)
      sleep_mul = 60.0 / bpm
      Thread.current.thread_variable_set(:sonic_pi_spider_sleep_mul, sleep_mul)
      block.call
      Thread.current.thread_variable_set(:sonic_pi_spider_sleep_mul, current_mul)
    end

    doc name:           :sleep,
        doc:            "",
        args:           [[:seconds, :number]],
        opts:           nil,
        accepts_block:  false,
        examples:       []
    def sleep(seconds)
      sleep_time = seconds * Thread.current.thread_variable_get(:sonic_pi_spider_sleep_mul)
      last = Thread.current.thread_variable_get :sonic_pi_spider_time
      now = Time.now

      new_t = last + sleep_time
      if now > new_t
        Thread.current.priority = 2
        __message "Can't keep up..."
      else
        Kernel.sleep new_t - now
      end

      Thread.current.thread_variable_set :sonic_pi_spider_time, new_t

      ## reset control deltas now that time has advanced
      Thread.current.thread_variable_set :sonic_pi_control_deltas, {}
    end

    doc name:           :sync,
        doc:            "",
        args:           [[:sync_id, :symbol]],
        opts:           {:message => nil},
        accepts_block:  false,
        examples:       []
    def sync(sync_id, *opts)
      args_h = resolve_synth_opts_hash_or_array(opts)
      __no_kill_block do
        Kernel.sleep @sync_real_sleep_time
        @events.event("/spider_thread_sync/" + sync_id.to_s, {:time => Thread.current.thread_variable_get(:sonic_pi_spider_time), :val => args_h[:message]})
      end
    end

    doc name:           :wait,
        doc:            "",
        args:           [[:sync_id, :symbol]],
        opts:           nil,
        accepts_block:  false,
        examples:       []
    def wait(sync_id)
      p = Promise.new
      @events.oneshot_handler("/spider_thread_sync/" + sync_id.to_s) do |payload|
        p.deliver! payload
      end
      payload = p.get
      time = payload[:time]
      val = payload[:val]
      Thread.current.thread_variable_set :sonic_pi_spider_time, time
      val
    end

    doc name:           :in_thread,
        doc:            "",
        args:           [],
        opts:           {:name => nil},
        accepts_block:  true,
        examples:       []
    def in_thread(*opts, &block)
      args_h = resolve_synth_opts_hash_or_array(opts)
      name = args_h[:name]

      parent_t = Thread.current

      # Get copy of thread locals whilst we're sure they're not being modified
      # as we're in the thread parent_t
      parent_t_vars = {}
      parent_t.thread_variables.each do |v|
        parent_t_vars[v] = parent_t.thread_variable_get(v)
      end

      job_id = __current_job_id
      reg_with_parent_completed = Promise.new

      # Create the new thread
      t = Thread.new do

        Thread.new do
          Thread.current.thread_variable_set(:sonic_pi_thread_group, :in_thread_join)
          Thread.current.priority = -1
          # wait for all subthreads to finish before removing self from
          # the subthread tree
          t.join
          __join_subthreads(t)
          parent_t.thread_variable_get(:sonic_pi_spider_subthread_mutex).synchronize do
            parent_t.thread_variable_get(:sonic_pi_spider_subthreads).delete(t)
          end
        end

        Thread.current.thread_variable_set(:sonic_pi_thread_group, :job_subthread)
        # Copy thread locals across from parent thread to this new thread
        parent_t_vars.each do |k,v|
          Thread.current.thread_variable_set(k, v) unless k.to_s.start_with? "sonic_pi__not_inherited__"
        end

        # Reset subthreads thread local to the empty set. This shouldn't
        # be inherited from the parent thread.
        Thread.current.thread_variable_set :sonic_pi_spider_subthreads, Set.new

        # Give new thread a new subthread mutex
        Thread.current.thread_variable_set :sonic_pi_spider_subthread_mutex, Mutex.new

        # Give new thread a new no_kill mutex
        Thread.current.thread_variable_set :sonic_pi_spider_no_kill_mutex, Mutex.new

        # Wait for parent to deliver promise. Throws an exception if
        # parent dies before the promise is delivered, thus stopping
        # this thread from continually waiting for forgotten promises...
        wait_for_parent_thread!(parent_t, reg_with_parent_completed)

        # Attempt to associate the current thread with job with
        # job_id. This will kill the current thread if job is no longer
        # running.
        job_subthread_add(job_id, Thread.current, name)

        # Actually run the thread code specified by the user!
        begin
          block.call
        rescue Exception => e
          __error "Thread #{name} died: #{e.inspect}", e
        end

        # Disassociate thread with job as it has now finished
        job_subthread_rm(job_id, Thread.current)
      end

      # Whilst we know that the new thread is waiting on the promise to
      # be delivered, we can now add it to our list of subthreads. Using
      # the promise means that we can be assured that killing this
      # current thread won't create a zombie child thread as the child
      # thread will only continue exiting after it has been sucessfully
      # registered.

      parent_t.thread_variable_get(:sonic_pi_spider_subthread_mutex).synchronize do
        subthreads = parent_t.thread_variable_get :sonic_pi_spider_subthreads
        subthreads.add(t)
      end

      # Allow the subthread to continue running
      reg_with_parent_completed.deliver! true

      # Return subthread
      t
    end
  end
end
