require 'minitest/autorun'
require 'minitest/benchmark'

require 'set'

require File.expand_path(File.dirname(__FILE__)) + '/test_helper.rb'

describe Daybreak::DB do
  before do
    @db = Daybreak::DB.new DB_PATH
  end

  it 'should insert' do
    assert_equal @db[1], nil
    assert_equal @db.include?(1), false
    @db[1] = 1
    assert_equal @db[1], 1
    assert @db.has_key?(1)
    @db[1] = '2'
    assert_equal @db[1], '2'
    assert_equal @db.length, 1
  end

  it 'should support batch inserts' do
    @db.update(1 => :a, 2 => :b)
    assert_equal @db[1], :a
    assert_equal @db[2], :b
    assert_equal @db.length, 2
  end

  it 'should persist values' do
    @db['1'] = '4'
    @db['4'] = '1'
    assert_equal @db.sync, @db

    assert_equal @db['1'], '4'
    db2 = Daybreak::DB.new DB_PATH
    assert_equal db2['1'], '4'
    assert_equal db2['4'], '1'
    assert_equal db2.close, nil
  end

  it 'should persist after batch update' do
    @db.update!(1 => :a, 2 => :b)

    db2 = Daybreak::DB.new DB_PATH
    assert_equal db2[1], :a
    assert_equal db2[2], :b
    assert_equal db2.close, nil
  end

  it 'should persist after clear' do
    @db['1'] = 'xy'
    assert_equal @db.clear, @db
    @db['1'] = '4'
    @db['4'] = '1'
    assert_equal @db.close, nil

    @db = Daybreak::DB.new DB_PATH
    assert_equal @db['1'], '4'
    assert_equal @db['4'], '1'
  end

  it 'should persist after compact' do
    @db['1'] = 'xy'
    @db['1'] = 'z'
    assert_equal @db.compact(:force => true), @db
    @db['1'] = '4'
    @db['4'] = '1'
    assert_equal @db.close, nil

    @db = Daybreak::DB.new DB_PATH
    assert_equal @db['1'], '4'
    assert_equal @db['4'], '1'
  end

  it 'should reload database file in sync after compact' do
    db = Daybreak::DB.new DB_PATH

    @db['1'] = 'xy'
    @db['1'] = 'z'
    assert_equal @db.compact(:force => true), @db
    @db['1'] = '4'
    @db['4'] = '1'
    assert_equal @db.flush, @db

    db.sync
    assert_equal db['1'], '4'
    assert_equal db['4'], '1'
    db.close
  end

  it 'should reload database file in sync after clear' do
    db = Daybreak::DB.new DB_PATH

    @db['1'] = 'xy'
    @db['1'] = 'z'
    @db.clear
    @db['1'] = '4'
    @db['4'] = '1'
    @db.flush

    db.sync
    assert_equal db['1'], '4'
    assert_equal db['4'], '1'
    db.close
  end

  it 'should compact cleanly' do
    @db[1] = 1
    @db[1] = 1
    @db.sync

    size = File.stat(DB_PATH).size
    @db.compact(:force => true)
    assert_equal @db[1], 1
    assert size > File.stat(DB_PATH).size
  end

  it 'should allow for default values' do
    db = Daybreak::DB.new(DB_PATH, :default => 0)
    assert_equal db.default(1), 0
    assert_equal db[1], 0
    assert db.include? '1'
    db[1] = 1
    assert_equal db[1], 1
    db.default = 42
    assert_equal db['x'], 42
    db.close
  end

  it 'should handle default values that are procs' do
    db = Daybreak::DB.new(DB_PATH) {|key| set = Set.new; set << key }
    assert db.default(:test).include? 'test'
    assert db['foo'].is_a? Set
    assert db.include? 'foo'
    assert db['bar'].include? 'bar'
    db.default = proc {|key| [key] }
    assert db[1].is_a? Array
    assert db[2] == ['2']
    db.close
  end

  it 'should be able to sync competing writes' do
    @db.set! '1', 4
    db2 = Daybreak::DB.new DB_PATH
    db2.set! '1', 5
    @db.sync
    assert_equal @db['1'], 5
    db2.close
  end

  it 'should be able to handle another process\'s call to compact' do
    @db.lock { 20.times {|i| @db[i] = i } }
    db2 = Daybreak::DB.new DB_PATH
    @db.lock { 20.times {|i| @db[i] = i } }
    @db.compact(:force => true)
    db2.sync
    assert_equal 19, db2['19']
    db2.close
  end

  it 'can empty the database' do
    20.times {|i| @db[i] = i }
    @db.clear
    db2 = Daybreak::DB.new DB_PATH
    assert_equal nil, db2['19']
    db2.close
  end

  it 'should handle deletions' do
    @db[1] = 'one'
    @db[2] = 'two'
    @db.delete! 'two'
    assert !@db.has_key?('two')
    assert_equal @db['two'], nil

    db2 = Daybreak::DB.new DB_PATH
    assert !db2.has_key?('two')
    assert_equal db2['two'], nil
    db2.close
  end

  it 'should close and reopen the file when clearing the database' do
    begin
      1000.times {@db.clear}
    rescue
      flunk
    end
  end

  it 'should have threadsafe lock' do
    @db[1] = 0
    inc = proc { 1000.times { @db.lock {|d| d[1] += 1 } } }
    a = Thread.new &inc
    b = Thread.new &inc
    a.join
    b.join
    assert_equal @db[1], 2000
  end

  it 'should synchronize across processes' do
    @db[1] = 0
    @db.flush
    @db.close
    begin
      a = fork do
        db = Daybreak::DB.new DB_PATH
        1000.times do |i|
          db.lock { db[1] += 1 }
          db["a#{i}"] = i
          sleep 0.01 if i % 100 == 0
        end
        db.close
      end
      b = fork do
        db = Daybreak::DB.new DB_PATH
        1000.times do |i|
          db.lock { db[1] += 1 }
          db["b#{i}"] = i
          sleep 0.01 if i % 100 == 0
        end
        db.close
      end
      Process.wait a
      Process.wait b
      @db = Daybreak::DB.new DB_PATH
      1000.times do |i|
        assert_equal @db["a#{i}"], i
        assert_equal @db["b#{i}"], i
      end
      assert_equal @db[1], 2000
    rescue NotImplementedError
      warn 'fork is not available: skipping multiprocess test'
      @db = Daybreak::DB.new DB_PATH
    end
  end

  it 'should synchronize across threads' do
    @db[1] = 0
    @db.flush
    @db.close
    a = Thread.new do
      db = Daybreak::DB.new DB_PATH
      1000.times do |i|
        db.lock { db[1] += 1 }
        db["a#{i}"] = i
        sleep 0.01 if i % 100 == 0
      end
      db.close
    end
    b = Thread.new do
      db = Daybreak::DB.new DB_PATH
      1000.times do |i|
        db.lock { db[1] += 1 }
        db["b#{i}"] = i
        sleep 0.01 if i % 100 == 0
      end
      db.close
    end
    a.join
    b.join
    @db = Daybreak::DB.new DB_PATH
    1000.times do |i|
      assert_equal @db["a#{i}"], i
      assert_equal @db["b#{i}"], i
    end
    assert_equal @db[1], 2000
  end

  it 'should support background compaction' do
    @db[1] = 0
    @db.flush
    @db.close
    stop = false
    a = Thread.new do
      db = Daybreak::DB.new DB_PATH
      1000.times do |i|
        db.lock { db[1] += 1 }
        db["a#{i}"] = i
        sleep 0.01 if i % 100 == 0
      end
      db.close
    end
    b = Thread.new do
      db = Daybreak::DB.new DB_PATH
      1000.times do |i|
        db.lock { db[1] += 1 }
        db["b#{i}"] = i
        sleep 0.01 if i % 100 == 0
      end
      db.close
    end
    c = Thread.new do
      db = Daybreak::DB.new DB_PATH
      db.compact(:force => true) until stop
      db.close
    end
    d = Thread.new do
      db = Daybreak::DB.new DB_PATH
      db.compact(:force => true) until stop
      db.close
    end
    stop = true
    a.join
    b.join
    c.join
    d.join
    @db = Daybreak::DB.new DB_PATH
    1000.times do |i|
      assert_equal @db["a#{i}"], i
      assert_equal @db["b#{i}"], i
    end
    assert_equal @db[1], 2000
  end

  it 'should support compact in lock' do
    @db[1] = 2
    @db.lock do
      @db[1] = 2
      @db.compact(:force => true)
    end
  end

  it 'should support clear in lock' do
    @db[1] = 2
    @db.lock do
      @db[1] = 2
      @db.clear
    end
  end

  it 'should support flush in lock' do
    @db[1] = 2
    @db.lock do
      @db[1] = 2
      @db.flush
    end
  end

  it 'should support set! and delete! in lock' do
    @db[1] = 2
    @db.lock do
      @db.set!(1, 2)
      @db.delete!(1)
    end
  end

  it 'should allow for inheritance' do
    class Subclassed < Daybreak::DB
      def increment(key, amount = 1)
        lock { self[key] += amount }
      end
    end

    db = Subclassed.new DB_PATH
    db[1] = 1
    assert_equal db.increment(1), 2
    db.clear
    db.close
  end

  after do
    @db.clear
    @db.close
  end
end
