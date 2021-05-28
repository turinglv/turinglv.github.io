---
title: MySQL -- redolog&&binlog
date: 2020-01-05
categories:
    - Storage
    - MySQL
tags:
    - Storage
    - MySQL
typora-root-url: ../../source

---

### 更新语句
```sql
create table T(ID int primary key, c int);

update T set c=c+1 where ID=2;
```
### 执行过程
<img src="/images/mysql-redo-binlog/0d2070e8f84c4801adbfa03bda1f98d9.png" alt="img" style="zoom:30%;" />

1. 通过连接器，客户端与MySQL建立连接
2. update语句会把**T表上的所有查询缓存清空**
3. 分析器会通过词法分析和语法分析识别这是一条更新语句
4. 优化器会决定使用id这个索引（聚簇索引）
5. 执行器负责具体执行，找到匹配的一行，然后更新
6. 更新过程中还会涉及**redolog**（重做日志）和**binlog**（归档日志）的操作

### redolog – InnoDB

- 如果每一次的更新操作都需要写进磁盘，然后磁盘也要找到对应的那条记录，然后再更新，整个过程**IO** 成本、查找成本都很高

  - **IO成本**就是寻址时间和上下文切换所需要的时间，最主要是用户态和内核态的上下文切换。用户态是无法直接访问磁盘等硬件上的数据的，只能通过操作系统去调内核态的接口，用内核态的线程去访问。 这里的上下文切换指的是同进程的线程上下文切换，所谓上下文就是线程运行需要的环境信息。 首先，用户态线程需要将一些中间计算结果保存CPU寄存器，保存CPU指令的地址到程序计数器（执行顺序保证），还要保存栈的信息等一些线程私有的信息。 然后切换到内核态的线程执行，就需要把线程的私有信息从寄存器，程序计数器里读出来，然后执行读磁盘上的数据。读完后返回，又要把线程的信息写进寄存器和程序计数器。 切换到用户态后，用户态线程又要读之前保存的线程执行的环境信息出来，恢复执行。这个过程主要是消耗时间资源。

- 为了解决这个问题，MySQL 使用的是 WAL 技术( Write-Ahead Logging)：**先写日志，再写磁盘**

- 当有一条记录需要更新的时候，InnoDB会把记录先写入redolog（redolog buffer），并**更新内存**（buffer pool）

  - InnoDB会在适当的时候（例如系统空闲），将这个操作记录到磁盘里面（**刷脏页**）

- InnoDB 的 redo log 是固定大小的，比如可以配置为一组 4 个文件，每个文件的大小是 1GB

  <img src="/images/mysql-redo-binlog/16a7950217b3f0f4ed02db5db59562a7.png" alt="img" style="zoom:40%;" />

  - redo log的总大小为4G，**循环写**
  - write pos 是当前记录的位置，一边写一边后移，写到第 3 号文件末尾后就回到 0 号文件开头
    - redolog是**顺序写**，数据文件是**随机写**
  - checkpoint 是当前要擦除的位置，也是往后推移并且循环的，擦除记录前要把记录更新到数据文件
  - write pos 和 checkpoint 之间空闲部分，可以用来记录新的操作
    - write pos 追上 checkpoint，磁盘写满，不能再执行新的更新，需要擦掉一些记录，把 checkpoint 推进一下
    - write pos 未追上 checkpoint，可以执行新的更新
    - 果checkpoint赶上了write pos，说明redolog已**空**

- 有了 redo log，InnoDB 就可以保证即使数据库发生异常重启，之前提交的记录都不会丢失，这个能力称为 crash-safe

- 如果redolog太小，会导致很快被写满，然后就不得不强行刷redolog，导致频繁刷盘，这样WAL机制的能力就无法发挥出来

  - 如果磁盘能达到几TB，那么可以将redolog设置4个一组，每个日志文件大小为1GB

```
# innodb_log_file_size -> 单个redolog文件的大小
# innodb_log_files_in_group -> redolog文件个数
# 50331648 Byte = 48 MB
mysql> SHOW VARIABLES LIKE '%innodb_log_file%';
+---------------------------+----------+
| Variable_name             | Value    |
+---------------------------+----------+
| innodb_log_file_size      | 50331648 |
| innodb_log_files_in_group | 2        |
+---------------------------+----------+
```

```
mysql> SHOW VARIABLES LIKE '%innodb_flush_log_at_trx_commit%';
+--------------------------------+-------+
| Variable_name                  | Value |
+--------------------------------+-------+
| innodb_flush_log_at_trx_commit | 1     |
+--------------------------------+-------+
```

**官网文档解释**：[innodb_flush_log_at_trx_commit](https://dev.mysql.com/doc/refman/5.6/en/innodb-parameters.html#sysvar_innodb_flush_log_at_trx_commit)

`innodb_flush_log_at_trx_commit` 作用于事务提交时：

- 1: 每次事务提交都要做一次fsync，这是最安全的配置，即使宕机也不会丢失事务；
- 2: 则在事务提交时只做write操作，只保证写到系统的page cache，因此实例crash不会丢失事务，但宕机则可能丢失事务；
- 0: 事务提交不会触发redo写操作，而是留给后台线程每秒一次的刷盘操作，因此实例crash将最多丢失1秒钟内的事务。

<img src="/images/mysql-redo-binlog/5.png" alt="redo持久化程度" style="zoom:80%;" />

### binlog - Server
- redo log属于InnoDB引擎特有的日志，Server层也有自己的日志，称为 **binlog**（归档日志）
- **为什么会有两份日志呢？**
  - 一开始并没有InnoDB，采用的是MyISAM，但**MyISAM没有crash-safe的能力**，**binlog日志只能用于归档**
  - InnoDB是以插件的形式引入MySQL的，**为了实现crash-safe**，InnoDB采用了**redolog**的方案
- binlog一开始的设计就是**不支持崩溃恢复**（原库）的，如果不考虑搭建从库等操作，**binlog是可以关闭的**（sql_log_bin）
- redolog vs binlog
  - redo log 是 InnoDB 引擎特有的；binlog 是 MySQL 的 Server 层实现的，所有引擎都可以使用
  - redo log 是物理日志，记录的是“在某个数据页上做了什么修改”；binlog 是逻辑日志，记录的是这个语句的原始逻辑，比如“给 ID=2 这一行的 c 字段加 1 ”
    - 逻辑日志：**提供给别的引擎用**，是大家都能理解的逻辑，例如**搭建从库**
    - 物理日志：**只能内部使用**，其他引擎无法共享内部的物理格式
  - redo log 是**循环写**，**空间固定**，**不能持久保存**，没有**归档**功能； binlog是**追加写**，**空间不受限制**，有**归档**功能
  - MySQL **InnoDB事务的持久性(Durability)**是通过redolog实现
  - binlog有两种模式：
    - **statement格式**：SQL语句
    - **row格式**：行内容（记两条，更新前和更新后），**推荐**
      - 日志一样的可以用于**重放**
```
mysql> SHOW VARIABLES LIKE '%sql_log_bin%';
+---------------+-------+
| Variable_name | Value |
+---------------+-------+
| sql_log_bin   | ON    |
+---------------+-------+
```

### update 内部流程

```sql
create table T(ID int primary key, c int);

update T set c=c+1 where ID=2;
```

<img src="/images/mysql-redo-binlog/mysql-innodb-update-procedure-1.jpg" alt="img" style="zoom:45%;" />

注：深绿色是在Server层执行，浅绿色是在InnoDB引擎中执行。

1. 执行器先通过InnoDB获取id=2这一行，id是主键，InnoDB可以通过聚簇索引找到这一行
   - 如果**id=2这一行所在的数据页**本来就在内存（**InnoDB Buffer Pool**）中，直接返回给执行器
   - 否则先从磁盘读入内存，然后再返回
2. 执行器拿到InnoDB返回的行数据，进行**+1**操作，得到新的一行数据，再调用InnoDB的引擎接口写入这行数据
3. InnoDB首先将这行新数据更新到内存（InnoDB Buffer Pool）中，同时将这个更新操作记录到redolog（物理记录）
   - 更新到内存中，在事务提交后，后续的查询就可以直接在内存中读取该数据页，但此时的数据可能还没有真正落盘
     - 但在**事务提交前，其他事务是无法看到这个内存修改的**
     - 而在**事务提交后，说明已经成功写入了redolog，可崩溃恢复，不会丢数据，因此可以直接读内存的数据**
   - 刚更新的内存是不会删除的，除非内存不够用，在数据从内存删除之前，系统会保证它们已经落盘
   - 此时redolog处于prepare状态（prepare标签），然后告诉执行器执行完成，随时可以提交事务
     - 对其他事务来说，刚刚修改的内存是**不可见**的
4. 执行器生成这个操作的binlog（逻辑记录）并写入磁盘
   - binlog写成功事务就算成功，可以提交事务
     - 哪怕崩溃恢复，也会恢复binlog写成功的事务（此时对应的redolog处于prepare状态）
   - binlog如果没写成功就回滚，回滚会写redolog，打上rollback标签，binlog则会直接丢弃
     - 如果binlog不丢弃，则会传播到从库
5. 执行器调用InnoDB的提交事务接口，InnoDB把刚刚写入的redolog改成commit状态，更新完成
   - redolog打上了**commit标签**
   - commit表示两个日志都生效了
   - commit完成后才会返回客户端

[sync_binlog](https://dev.mysql.com/doc/refman/5.6/en/replication-options-binary-log.html#sysvar_sync_binlog)

```
mysql> SHOW VARIABLES LIKE '%sync_binlog%';
+---------------+-------+
| Variable_name | Value |
+---------------+-------+
| sync_binlog   | 1     |
+---------------+-------+
1 row in set (0.01 sec)
```

**sync_binlog参数：**

- 0：每次事务提交后，将Binlog Cache中的数据写入到Binlog文件，但不立即刷新到磁盘。由文件系统(file system)决定何时刷新到磁盘中
- 1：每次事务提交后，将Binlog Cache中的数据写入到Binlog文件,调用fdatasync()函数将数据刷新到磁盘中
- N:  每N次事务提交后，将Binlog Cache中的数据写入到Binlog文件,调用fdatasync()函数将数据刷新到磁盘中

### sync_binlog & innodb_flush_log_at_trx_commit 最佳实践

| innodb_flush_log_at_trx_commit | sync_binlog  | 描述                                                         |
| ------------------------------ | ------------ | ------------------------------------------------------------ |
| 1                              | 1            | 适合数据安全性要求非常高，而且磁盘写入能力足够支持业务。     |
| 1                              | 0            | 适合数据安全性要求高，磁盘写入能力支持业务不足，允许备库落后或无复制。 |
| 2                              | 0/N(0<N<100) | 适合数据安全性要求低，允许丢失一点事务日志，允许复制延迟。   |
| 0                              | 0            | 磁盘写能力有限，无复制或允许复制延迟较长。                   |

### 两阶段提交
1. 目的：为了让两份日志之间的逻辑一致
2. 如果不使用两阶段提交：
   - 先写 redo log 后写 binlog
     - 产生问题：假设 redo log 写成功（落盘成功），binlog 还没有写完（暂未落盘成功），MySQL 进程异常重启，
       MySQL重启恢复可以使用redo log将数据恢复，如果使用binlog恢复临时库，因为binlog缺失数据，会导致数据与原库不一致
   - 先写 binlog 后写 redo log
     - 产生问题：假设 binlog 写成功（落盘成功），redo log 还没有写完（暂未落盘成功），MySQL 进程异常重启，MySQL重启恢复无法使用redo log将数据恢复，但是因为binlog记录了最新的更新操作，使用binlog恢复数据的时候会导致数据与原库不一致

### binlog、redolog功能区别
   - redolog
     - 保证crash-safe，事务的持久性
     - **物理格式的日志**，记录的是物理数据页面的修改的信息
     - 将随机写变成顺序写，提高MySQL吞吐
   - binlog：
     - **逻辑日志**，没有记录数据页的更新细节，***没有能力恢复数据页***
     - **归档**功能，redolog是循环写，起不到归档的作用
     - ***binlog复制：MySQL高可用的基础***
       - **主从复制**
       - 异构系统（如数据分析系统）会**消费MySQL的binlog**来更新自己的数据

### 崩溃恢复
- 判断规则
  1. 如果 redo log 里面的事务是完整的，也就是已经有了 commit 标识，则直接提交；
  2. 如果 redo log 里面的事务只有完整的 prepare，则判断对应的事务 binlog 是否存在并完整：
     a. 如果是，则提交事务
     b. 否则，回滚事务
     注：时刻 B 发生 crash 对应的就是 2(a) 的情况，崩溃恢复过程中事务会被提交
- redo log 和 binlog 关联
  - 通过共同数据字段， XID（**为每个事务分配一个唯一的ID**）
  - 崩溃恢复的时候，会按顺序扫描 redo log
    - 如果碰到既有 prepare、又有 commit 的 redo log，就直接提交
    - 如果碰到只有 parepare、而没有 commit 的 redo log，就拿着 XID 去 binlog 找对应的事务
- binlog 完整性判断
  - statement 格式的 binlog，最后会有 COMMIT
  - row 格式的 binlog，最后会有一个 XID event 
  - 在 MySQL 5.6.2 版本以后，引入了 binlog-checksum 参数，用来验证 binlog 内容的正确性
    - binlog可能由于**磁盘原因**，在**日志中间**出错，MySQL可以通过校验checksum来发现

### 异常点说明

- 时刻A

  - 属于判断规则 2(b) 情况
  - **redolog处于prepare阶段**，**binlog未写成功**，在崩溃恢复时，事务**回滚**
  - 由于binlog未写成功，所以无法传播给从库或异架数据库

- 时刻B

  - 属于判断规则 2(a) 情况，事务提交

  - **redolog处于prepare阶段**，**binlog写成功**，在崩溃恢复时，事务**提交**

  - 由于binlog写成功，所以可以传播给从库或异架数据库，数据保持一致

    思考：为何MySQL这么设计？

    - binlog 写完以后 MySQL 发生崩溃，这时候 binlog 已经写入了，之后就会被从库（或者用这个 binlog 恢复出来的库）使用。所以，在主库上也要提交这个事务。采用这个策略，主库和备库的数据就保证了一致性。

### 参考资料

《MySQL实战45讲》
