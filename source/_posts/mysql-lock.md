---
title: MySQL -- 锁
date: 2020-01-20
categories:
    - Storage
    - MySQL
tags:
    - Storage
    - MySQL
typora-root-url: ../../source

---

## Mysql 锁总结

### 加锁机制

- 乐观锁
- 悲观锁

乐观锁与悲观锁是两种并发控制的思想，可用于解决丢失更新的问题：
1. 乐观锁会"乐观的"假定大概率不会发生并发更新冲突，访问、处理数据过程中不加锁，只在更新数据时再根据版本号或时间戳判断是否有冲突，有则处理，无则提交事务
2. 悲观锁会"悲观的"假定大概率会发生并发更新冲突，访问、处理数据前就加排他锁，在整个数据处理过程中锁定数据，事务提交或回滚后才释放锁；

### 兼容性

- 共享锁（读锁、S Lock）
- 排它锁（写锁、X Lock）

|      | X      | S      |
| ---- | ------ | ------ |
| X    | 不兼容 | 不兼容 |
| S    | 不兼容 | 兼容   |

### 锁粒度

- 全局锁
- 表锁
- 页锁
- 行锁

### 锁类型

- MetaDataLock（元数据锁 MDL）
- 行锁
- gap锁
- next-key lock
- 意向锁
- 插入意向锁
- 自增锁

## 全局锁

全局锁就是对整个数据库实例加锁。MySQL 提供了一个加全局读锁的方法，命令是 Flush tables with read lock (FTWRL)。
之后其他线程的以下语句会被阻塞：数据更新语句（数据的增删改）、数据定义语句（包括建表、修改表结构等）和更新类事务的提交语句。
全局锁的典型使用场景是，做全库逻辑备份。也就是把整库每个表都 select 出来存成文本。
FTWRL通过持有以下两把全局的MDL(MetaDataLock)锁：

- 全局读锁(lock_global_read_lock) 会导致所有的更新操作被堵塞
- 全局COMMIT锁(make_global_read_lock_block_commit) 会导致所有的活跃事务无法提交

FLUSH TABLES WITH READ LOCK执行后整个系统会一直处于只读状态，直到显示执行UNLOCK TABLES

## MDL

### MDL作用

​	为了在并发环境下维护表元数据的数据一致性，在表上有活动事务（显式或隐式）的时候，不可以对元数据进行写入操作。因此从MySQL5.5版本开始引入了MDL锁（metadata lock），来保护表的元数据信息，用于解决或者保证DDL操作与DML操作之间的一致性。
​	对于引入MDL，其主要解决了2个问题，一个是事务隔离问题，比如在可重复隔离级别下，会话A在2次查询期间，会话B对表结构做了修改，两次查询结果就会不一致，无法满足可重复读的要求；另外一个是数据复制的问题，比如会话A执行了多条更新语句期间，另外一个会话B做了表结构变更并且先提交，就会导致slave在重做时，先重做alter，再重做update时就会出现复制错误的现象。
​	所以在对表进行上述操作时，如果表上有活动事务（未提交或回滚），请求写入的会话会等待在Metadata lock wait 。

| 会话1             | 会话2          |
| ----------------- | -------------- |
| BEGIN;            |                |
| SELECT * FROM XXX |                |
|                   | DROP TABLE XXX |
| SELECT * FROM XXX |                |

​	若没有MDL锁的保护，则事务2可以直接执行DDL操作，并且导致事务1出错，5.1版本即是如此。5.5版本加入MDL锁就在于保护这种情况的发生，由于事务1开启了查询，那么获得了MDL锁，锁的模式为SHARED_READ，事务2要执行DDL，则需获得EXCLUSIVE锁，两者互斥，所以事务2需要等待。

### MDL锁类型

由于MySQL是Server-Engine架构，尽管InnoDB层已经有了IS、IX这样的意向锁，所以MDL锁是在Server中实现

MDL锁还能实现其他粒度级别的锁，比如全局锁、库级别的锁、表空间级别的锁，这是InnoDB存储引擎层不能直接实现的锁

与InnoDB锁的实现一样，MDL锁也是类似对一颗树的各个对象从上至下进行加锁。但是MDL锁对象的层次更多，简单来看有如下的层次：

<img src="/images/mysql-lock/0823959122513a6fe17bc80567715e03.png" alt="img" style="zoom:150%;" />

上图中显示了最常见的4种MDL锁的对象，并且注明了常见的SQL语句会触发的锁。

与InnoDB层类似的是，某些类型的MDL锁会从上往下一层层进行加锁。

比如LOCK TABLE … WRITE这样的SQL语句，其首先会对GLOBAL级别加INTENTION_EXCLUSIVE锁，再对SCHEMA级别加INTENTION_EXCLUSIVE锁，最后对TABLE级别加SHARED_NO_READ_WRITE锁

### MDL锁对象、范围

| 属性      | 含义                | 范围/对象 | 作用                                                         |
| --------- | ------------------- | --------- | ------------------------------------------------------------ |
| GLOBAL    | 全局锁（MySQL实例） | 范围      | 主要作用是防止DDL和写操作的过程中执行 set golbal_read_only =on 或<br />flush tables with read *lock*; |
| COMMIT    | 提交保护锁          | 范围      | 主要作用是执行flush tables with read *lock*后，防止已经开始在执行的写事务提交 |
| SCHEMA    | 库锁                | 对象      |                                                              |
| TABLE     | 表锁                | 对象      |                                                              |
| FUNCTION  | 函数锁              | 对象      |                                                              |
| PROCEDURE | 存储过程锁          | 对象      |                                                              |
| TRIGGER   | 触发器锁            | 对象      |                                                              |
| EVENT     | 事件锁              | 对象      |                                                              |

### MDL持有时间

| 属性            | 含义                                                         |
| --------------- | ------------------------------------------------------------ |
| MDL_STATEMENT   | 从语句开始执行时获取，到语句执行结束时释放。                 |
| MDL_TRANSACTION | 在一个事务中涉及所有表获取MDL，一直到事务commit或者rollback(线程中终清理)才释放。 |
| MDL_EXPLICIT    | 需要MDL_context::release_lock()显式释放。语句或者事务结束,也仍然持有，如Lock table, flush .. with lock语句等。 |

### MDL锁模式

数据库锁一般将锁划分为读锁(共享锁)和写锁(排它锁)，为了进一步提高并发性，还会加入意向共享锁和意向排它锁。

mysql设计得更复杂，如下表：

| 锁模式                    | 对应SQL                                                      |
| ------------------------- | ------------------------------------------------------------ |
| MDL_INTENTION_EXCLUSIVE   | 意向排他锁 GLOBAL对象、SCHEMA对象操作会加此锁                |
| MDL_SHARED                | 只访问元数据 比如表结构 FLUSH TABLES with READ LOCK          |
| MDL_SHARED_HIGH_PRIO      | 仅对MyISAM存储引擎有效，用于访问information_scheam表         |
| MDL_SHARED_READ           | SELECT查询 访问表结构并且读表数据                            |
| MDL_SHARED_WRITE          | DML语句 访问表结构并且写表数据                               |
| MDL_SHARED_WRITE_LOW_PRIO | 仅对MyISAM存储引擎有效                                       |
| MDL_SHARED_UPGRADABLE     | ALTER TABLE是mysql5.6引入的新的metadata lock, 在alter table/create index/drop index会加该锁。特点是允许DML，防止DDL； |
| MDL_SHARED_READ_ONLY      | LOCK xxx READ                                                |
| MDL_SHARED_NO_WRITE       | FLUSH TABLES xxx,yyy,zzz READ可升级锁，访问表结构并且读写表数据，并且禁止其它事务写。 |
| MDL_SHARED_NO_READ_WRITE  | FLUSH TABLE xxx WRITE可升级锁，访问表结构并且读写表数据，并且禁止其它事务读写。 |
| MDL_EXCLUSIVE             | ALTER TABLE xxx PARTITION BY …防止其他线程读写元数据         |

### Online DDL过程

1. 拿MDL写锁 ： 当A、B线程都来做DDL的时候，如A拿到了DDL写锁，B就阻塞，其它读数据的线程阻塞，该步执行时间短
2. DDL执行准备： 当A、B线程都来做DDL的时候，如A拿到了DDL写锁，B任然阻塞，其它读数据的线程阻塞，该步执行时间短
3. 降级成MDL读锁 ： 当A、B线程都来做DDL的时候，如A拿到了DDL写锁，B任然阻塞，其它读数据的线程可以读取数据，该步执行时间短
4. DDL核心执行：（耗时最多的） 当A、B线程都来做DDL的时候，如A拿到了DDL写锁，B任然阻塞，其它读数据的线程可以读取数据（关键是其它线程可以读取数据），该步执行时间长，所以号称在线DDL，因为影响业务线程读取数据的时间很短
5. 升级成MDL写锁: 当A、B线程都来做DDL的时候，如A拿到了DDL写锁，B任然阻塞，，其它读数据的线程阻塞，该步执行时间短
6. DDL最终提交 ： 当A、B线程都来做DDL的时候，如A拿到了DDL写锁，B任然阻塞，，其它读数据的线程阻塞，该步执行时间短
7. 释放MDL锁 ： 当A、B线程都来做DDL的时候，如A释放写锁，B拿到DDL锁，，其它读数据的线程阻塞，该步执行时间短，继续循环上面个的步骤

## 表级锁

**表锁的语法是 lock tables … read/write**
可以用 unlock tables 主动释放锁，也可以在客户端断开的时候自动释放。
需要注意，lock tables 语法除了会限制别的线程的读写外，也限定了本线程接下来的操作对象

例如：
线程 A 中执行 lock tables t1 read, t2 write; 
这个语句，则其他线程写 t1、读写 t2 的语句都会被阻塞。
同时，线程 A 在执行 unlock tables 之前，也只能执行读 t1、读写 t2 的操作。连写 t1 都不允许，自然也不能访问其他表

**InnoDB 这种支持行锁的引擎**，一般不使用 lock tables 命令来控制并发，毕竟锁住整个表的影响面还是太大

MySQL 5.5 版本中引入了 MDL，当对一个表做增删改查操作的时候，加 MDL 读锁；当要对表做结构变更操作的时候，加 MDL 写锁。

MDL 锁是系统默认添加的

- 读锁之间不互斥，因此你可以有多个线程同时对一张表增删改查。

- 读写锁之间、写锁之间是互斥的，用来保证变更表结构操作的安全性。因此，如果有两个线程要同时给一个表加字段，其中一个要等另一个执行完才能开始执行。


Table MDL事故分析：给一个小表加个字段，导致整个库挂了

<img src="/images/mysql-lock/7cf6a3bf90d72d1f0fc156ececdfb0ce.jpg" alt="img" style="zoom:50%;" />

session A 先启动，这时候会对表 t 加一个 MDL 读锁。由于 session B 需要的也是 MDL 读锁，因此可以正常执行。
session C 会被 blocked，是因为 session A 的 MDL 读锁还没有释放，而 session C 需要 MDL 写锁，因此只能被阻塞。
**因为：**申请MDL锁的操作会形成一个队列，队列中写锁获取优先级高于读锁。一旦出现写锁等待，不但当前操作会被阻塞，同时还会阻塞后续该表的所有操作。事务一旦申请到MDL锁后，直到事务执行完才会将锁释放。
所以session D也会因为session C而被blocked

针对以上事故最佳实践：
1. 解决长事务，事务不提交，就会一直占着 MDL 锁。要考虑先暂停 DDL，或者 kill 掉这个长事务
2. 比较理想的机制是，在 alter table 语句里面设定等待时间，如果在这个指定的等待时间里面能够拿到 MDL 写锁最好，
   拿不到也不要阻塞后面的业务语句，先放弃。之后开发人员或者 DBA 再通过重试命令重复这个过程（注意mysql版本，是否支持该语法）

## 意向锁

- 意向锁是一种特殊的**表级锁**，意向锁是为了让 InnoDB 多粒度的锁能共存而设计的
- 意向锁分为：
  - **意向共享锁**(intention shared lock, IS)，它预示着，事务有意向对表中的某些行加共享S锁
  - **意向排它锁**(intention exclusive lock, IX)，它预示着，事务有意向对表中的某些行加排它X锁
  - select ... lock in share mode，要设置**IS锁**；select ... for update，要设置**IX锁**；
- 意向锁协议(intention locking protocol)：
  - 事务要获得某些行的**S锁**，必须先获得表的**IS锁**
  - 事务要获得某些行的**X锁**，必须先获得表的**IX锁**
  - 意向共享锁和意向排他锁都是系统自动添加和自动释放的，整个过程无需人工干预
- 主要是用来辅助表级和行级锁的冲突判断，因为 Innodb 支持行级锁，如果没有意向锁，则判断表锁和行锁冲突的时候需要遍历表上所有行锁，有了意向锁，则只要判断表是否存在意向锁就可以知道是否有行锁了。表级别锁的兼容性如下表：

| 是否兼容当前锁模式 | X    | IX   | S    | IS   |
| ------------------ | ---- | ---- | ---- | ---- |
| X                  | 冲突 | 冲突 | 冲突 | 冲突 |
| IX                 | 冲突 | 兼容 | 冲突 | 兼容 |
| S                  | 冲突 | 冲突 | 兼容 | 兼容 |
| IS                 | 冲突 | 兼容 | 兼容 | 兼容 |

意向锁与意向锁兼容，IX、IS 自身以及相互都兼容，不互斥，因为意向锁仅表示下一层级加什么类型的锁，不代表当前层加什么类型的锁；
IX 和表级 X、S 互斥；IS 和表级 X 锁互斥。其兼容性正好体现了其作用

**比如**：事务A要在一个表上加S锁，如果表中的一行已被事务B加了X锁，那么该锁的申请也应被阻塞
如果表中的数据很多，逐行检查锁标志的开销将很大，系统的性能将会受到影响，因为事务B已经设置了IX锁，所以无需逐行遍历了

## 自增锁

- 自增锁是一种特殊的表级锁，主要用于事务中插入自增字段，也就是我们最常用的自增主键id
1. 自增锁不是事务锁，每次申请完就马上释放，以便其它事务再申请
2. MySQL 5.0，自增锁的范围是语句级别
   - 一个语句申请了自增锁，需要等到语句结束后才会释放，***影响并发度***
3. MySQL 5.1.22，引入了一个新策略，新增参数innodb_autoinc_lock_mode，默认值为1
   - `innodb_autoinc_lock_mode=0`，表示采用之前MySQL 5.0的策略，**语句级别**
   - `innodb_autoinc_lock_mode=1`
     - 普通`INSERT`语句，自增锁在申请后**马上释放**，包括批量的`INSERT INTO...VALUES`
     - 类似`INSERT...SELECT`这样的**批量插入**（无法明确数量）的语句，还是**语句级别**
   - `innodb_autoinc_lock_mode=2`，所有的申请自增id的动作都是**申请后就释放锁**

## 插入意向锁（Insert Intention Locks）

[MySql 手册](https://link.juejin.cn/?target=https%3A%2F%2Fdev.mysql.com%2Fdoc%2Frefman%2F8.0%2Fen%2Finnodb-locking.html%23innodb-insert-intention-locks) 是如何解释 **InnoDB** 中的`插入意向锁`的：

```
An insert intention lock is a type of gap lock set by INSERT operations prior to row insertion. This lock signals the intent to insert in such a way that multiple transactions inserting into the same index gap need not wait for each other if they are not inserting at the same position within the gap. Suppose that there are index records with values of 4 and 7. Separate transactions that attempt to insert values of 5 and 6, respectively, each lock the gap between 4 and 7 with insert intention locks prior to obtaining the exclusive lock on the inserted row, but do not block each other because the rows are nonconflicting.
```

`插入意向锁`的特性可以分成两部分：

1. `插入意向锁`是一种特殊的`间隙锁` —— `间隙锁`可以锁定**开区间**内的部分记录。
2. 插入意向锁是在插入一条记录行前，由 **INSERT** 操作产生的一种间隙锁
3. `插入意向锁`之间互不排斥，所以即使多个事务在同一区间插入多条记录，只要记录本身（`主键`、`唯一索引`）不冲突，那么事务之间就不会出现**冲突等待**。
4. 虽然`插入意向锁`中含有`意向锁`三个字，但是它并不属于`意向锁`而属于`间隙锁`，因为`意向锁`是**表锁**而`插入意向锁`是**行锁**

## 行锁、Gap锁、Next-key Lock

### 行锁

1. MySQL的行锁是在**存储引擎层**实现的
2. MyISAM不支持行锁，而InnoDB支持行锁，这是InnoDB替代MyISAM的一个重要原因

#### 两阶段锁

1. 两阶段锁
   - 在InnoDB事务中，行锁是在**需要的时候**加上
   - 但并不是在不需要了就立刻释放，而是要等待**事务结束**后才释放
2. 如果事务需要**锁定多行**，要就把最可能**造成锁冲突**和**影响并发度**的锁尽可能**往后放**

#### 死锁

<img src="/images/mysql-lock/mysql-innodb-dead-lock.jpg" alt="img" style="zoom:50%;" />

1. 事务A在等待事务B释放id=2的行锁，事务B在等待事务A释放id=1的行锁，导致**死锁**
2. 当出现死锁后，有2种处理策略
   - 等待，直至超时（不推荐）
     - **业务有损**：业务会出现大量超时
   - 死锁检测（推荐）
     - **业务无损**：业务设计不会将死锁当成严重错误，当出现死锁时可采取：***事务回滚+业务重试***

#### 锁等待

1. 由参数`innodb_lock_wait_timeout`控制（MySQL 5.7.15引入）
2. 默认是50s，对于**在线服务**来说是无法接受的
3. 但也**不能设置成很小的值**，因为如果实际上并不是死锁，只是简单的锁等待，会出现很多**误伤**

#### 死锁检测（推荐）

1. 发现死锁后，主动回滚锁链条中的某一事务，让其他事务继续执行
   - 需要设置参数`innodb_deadlock_detect`
2. 触发死锁检测：**要加锁访问的行上有锁**
   - **一致性读不会加锁**
3. 死锁检测并不需要扫描所有事务
   - 某个时刻，事务等待状态为：事务B等待事务A，事务D等待事务C
   - 新来事务E，事务E需要等待D，那么只会判断事务CDE是否会形成死锁
4. CPU消耗高
   - 每个新来的线程发现自己要加锁访问的行上有锁
     - 会去判断会不会**由于自己的加入而导致死锁**，总体时间复杂度为 O(n²)
   - 假设有1000个并发线程，最坏情况下死锁检测的操作量级为100W（1000²）
     解释：假设有 1000 个并发线程，都要同时更新**同一行**，
     ​			**每个新来的被堵住的线程，都要判断会不会由于自己的加入导致了死锁**
     ​			第 1 个线程来的时候检测数是 0；
     ​			第 2 个线程来的时候，需要检测【线程1】有没有被别人锁住；
     ​			第 3 个线程来的时候，需要检测【线程1，线程2】有没有被其他线程锁住，
     ​			以此类推，第 n 个线程来的时候，检测数是 n - 1，
     ​			所以总的检测数是 0 + 1 + 2 + 3 + 。。。+ (n - 1) = n(n -1)/2，所以时间复杂度应该是 O(n²)
     ​			**也就是 1000 个并发线程同时操作同一行，那么死锁检测操作就是 100 万这个量级的**

5. 解决方法

   - 如果业务能确保一定不会出现死锁，可以**临时关闭死锁检测**，但存在一定的风险（超时）
   - 控制并发度，如果并发下降，那么死锁检测的成本就会降低，这需要在数据库服务端实现
     - 如果有**中间件**，可以在中间件实现
     - 如果能修改**MySQL源码**，可以在MySQL内部实现
   - 设计上的优化
     - 将一行改成**逻辑上的多行**来**减少锁冲突**

```sql
mysql> SHOW VARIABLES LIKE '%innodb_deadlock_detect%';
+------------------------+-------+
| Variable_name          | Value |
+------------------------+-------+
| innodb_deadlock_detect | ON    |
+------------------------+-------+

mysql> SHOW VARIABLES LIKE '%innodb_lock_wait_timeout%';
+--------------------------+-------+
| Variable_name            | Value |
+--------------------------+-------+
| innodb_lock_wait_timeout | 30    |
+--------------------------+-------+
```
### GAP Lock

1. 产生幻读的原因：行锁只能锁住行，新插入记录这个动作，要更新的是记录之间的**间隙**
2. 为了解决幻读，InnoDB引入了新的锁：**间隙锁**（**Gap Lock**）
3. 间隙锁的引入，可能会导致同样的语句锁住更大的范围，这其实是影响了并发度的

#### Gap Lock 作用场景

1. 对主键或唯一索引，如果当前读时，where条件全部精确命中(=或者in)，这种场景本身就不会出现幻读，所以只会加行记录锁
2. 没有索引的列，当前读操作时，会加全表gap锁，生产环境要注意
3. 非唯一索引列，如果where条件部分命中(>、<、like等)或者全未命中，则会加附近Gap间隙锁。
   例如，某表数据如下，非唯一索引2,6,9,9,11,15。如下语句要操作非唯一索引列9的数据，gap锁将会锁定的列是(6,11]，该区间内无法插入数据。

#### Gap Lock冲突关系

跟**间隙锁**存在冲突关系的是**往这个间隙插入一个记录的操作**，**间隙锁之间不会相互冲突**

```sql
CREATE TABLE `t` (
    `id` INT(11) NOT NULL,
    `c` INT(11) DEFAULT NULL,
    `d` INT(11) DEFAULT NULL,
    PRIMARY KEY (`id`),
    KEY `c` (`c`)
) ENGINE=InnoDB;

INSERT INTO t VALUES (0,0,0),(5,5,5),(10,10,10),(15,15,15),(20,20,20),(25,25,25);
```

| session A                                                  | session B                                         |
| :--------------------------------------------------------- | :------------------------------------------------ |
| BEGIN; <br />SELECT * FROM t WHERE c=7 LOCK IN SHARE MODE; |                                                   |
|                                                            | BEGIN;<br />SELECT * FROM t WHERE c=7 FOR UPDATE; |

1. session B并不会被阻塞，因为表t里面并没有c=7的记录
   - 因此session A加的是**间隙锁**`(5,10)`，而session B也是在这个间隙加间隙锁
   - 两个session有共同的目标： 保护这个间隙，不允许插入值，但两者之间不冲突

### Next-Key Lock

1. 间隙锁和行锁合称`Next-Key Lock`，每个`Next-Key Lock`都是**左开右闭**区间
2. `SELECT * FROM t WHERE d=5 FOR UPDATE;`形成了7个`Next-Key Lock`，分别是
   - `(-∞,0],(0,5],(5,10],(10,15],(15,20],(20,25],(25,+supremum]`
   - `+supremum`：InnoDB给每一个索引加的一个**不存在的最大值supremum**
3. 约定：`Gap Lock`为**左开右开**区间，`Next-Key Lock`为**左开右闭**区间

##  MySql 加锁规则

### 加锁逻辑

**两个“原则”、两个“优化”和一个“bug”**
MySQL 后面的版本可能会改变加锁策略，所以这个规则只限于截止到现在的最新版本，即 **5.x 系列 <=5.7.24**，**8.0 系列 <=8.0.13**

原则 1：加锁的基本单位是 next-key lock。next-key lock 是前开后闭区间。
原则 2：查找过程中访问到的对象才会加锁。
优化 1：索引上的等值查询，给唯一索引加锁的时候，next-key lock 退化为行锁。
优化 2：索引上的等值查询，向右遍历时且最后一个值不满足等值条件的时候，next-key lock 退化为间隙锁。
一个 bug：唯一索引上的范围查询会访问到不满足条件的第一个值为止。

优化及回滚策略：
1. 锁是**一个一个**加的，为了避免死锁，对**同一组资源**，尽量按照**相同的顺序**访问
2. 在发生死锁的时候，`FOR UPDATE`占用的资源更多，**回滚成本更大**，因此选择回滚`LOCK IN SHARE MODE`

### 锁兼容列表

| 是否兼容             | gap    | insert intention | record | next-key |
| -------------------- | ------ | ---------------- | ------ | -------- |
| **gap**              | 是     | 是               | 是     | 是       |
| **insert intention** | **否** | 是               | 是     | **否**   |
| **record**           | 是     | 是               | **否** | **否**   |
| **next-key**         | 是     | 是               | **否** | **否**   |

## 加锁、死锁分析

**没有明确说明的情况下 均为RR级别**

```sql
CREATE TABLE `t` (
  `id` int(11) NOT NULL,
  `c` int(11) DEFAULT NULL,
  `d` int(11) DEFAULT NULL,
  `e` int(11) DEFAULT NULL
  PRIMARY KEY (`id`),
  KEY `c` (`c`),
  UNIQUE KEY `d` (`d`)
) ENGINE=InnoDB;

insert into t values(0,0,0,0),(5,5,5,5),
(10,10,10,10),(15,15,15,15),(20,20,20,20),(25,25,25,25);
```

### 加锁分析

#### 唯一索引

1. 等值查询：命中降级成 Row Lock

   | session A                                    | session B                                           | session C                                       |
   | :------------------------------------------- | :-------------------------------------------------- | :---------------------------------------------- |
   | BEGIN; <br />UPDATE t SET d=d+1 WHERE id=10; |                                                     |                                                 |
   |                                              | INSERT INTO t VALUES(1,1,1,1); <br />(Query OK)     |                                                 |
   |                                              | INSERT INTO t VALUES(16,16,16,16); <br />(Query OK) |                                                 |
   |                                              |                                                     | UPDATE t SET d=d+1 WHERE id=5; <br />(Query OK) |
   |                                              |                                                     | UPDATE t SET d=d+1 WHERE id=10; <br />(Blocked) |

   session A持有的锁：`PRIMARY:X Lock:10`

2. 等值查询：不命中降级（**Next-Key Lock降级为Gap Lock**）

   | session A                                   | session B                                       | session C                                        |
   | :------------------------------------------ | :---------------------------------------------- | :----------------------------------------------- |
   | BEGIN; <br />UPDATE t SET d=d+1 WHERE id=7; |                                                 |                                                  |
   |                                             | INSERT INTO t VALUES(1,1,1,1); <br />(Query OK) |                                                  |
   |                                             | INSERT INTO t VALUES(8,8,8,8);<br />(Blocked)   |                                                  |
   |                                             |                                                 | UPDATE t SET d=d+1 WHERE id=5;<br />(Query OK)   |
   |                                             |                                                 | UPDATE t SET d=d+1 WHERE id=10; <br />(Query OK) |

   ```sql
   -- session B Blocked
   mysql> SELECT locked_index,locked_type,waiting_lock_mode,blocking_lock_mode FROM sys.innodb_lock_waits WHERE locked_table='`test`.`t`';
   +--------------+-------------+-------------------+--------------------+
   | locked_index | locked_type | waiting_lock_mode | blocking_lock_mode |
   +--------------+-------------+-------------------+--------------------+
   | PRIMARY      | RECORD      | X,GAP             | X,GAP              |
   +--------------+-------------+-------------------+--------------------+
   ```

   session A持有的锁：`PRIMARY:Gap Lock:(5,10)`

3. 范围查询 – 起点降级（**Next-Key Lock降级为Row Lock**）

   | session A                                                    | session B                                        | session C                                 |
   | :----------------------------------------------------------- | :----------------------------------------------- | :---------------------------------------- |
   | BEGIN; <br />SELECT * FROM t WHERE id>=10 AND id<11 FOR UPDATE; |                                                  |                                           |
   |                                                              | INSERT INTO t VALUES (8,8,8,8); <br />(Query OK) |                                           |
   |                                                              | INSERT INTO t VALUES (13,13,13,13); (Blocked)    |                                           |
   |                                                              |                                                  | UPDATE t SET d=d+1 WHERE id=10; (Blocked) |
   |                                                              |                                                  | UPDATE t SET d=d+1 WHERE id=15; (Blocked) |

   条件会拆分成`=10`（`Row Lock`）和`>10 & <11`，session A持有的锁：`PRIMARY:X Lock:10`+`PRIMARY:Next-Key Lock:(10,15]`

4. 范围查询 – 尾点延伸 （直到遍历到**第一个不满足的值**为止）

   | session A                                                    | session B                                     | session C                                 |
   | :----------------------------------------------------------- | :-------------------------------------------- | :---------------------------------------- |
   | BEGIN;<br />SELECT * FROM t WHERE id>10 AND id<=15 FOR UPDATE; |                                               |                                           |
   |                                                              | INSERT INTO t VALUES (16,16,16,16); (Blocked) |                                           |
   |                                                              |                                               | UPDATE t SET d=d+1 WHERE id=20; (Blocked) |

   session A持有的锁：`PRIMARY:Next-Key Lock:(10,15]`+`PRIMARY:Next-Key Lock:(15,20]`

#### 不唯一索引

1. 等值查询 – LOCK IN SHARE MODE

   | session A                                                   | session B                                       | session C                                       |
   | :---------------------------------------------------------- | :---------------------------------------------- | :---------------------------------------------- |
   | BEGIN; <br />SELECT id FROM t WHERE c=5 LOCK IN SHARE MODE; |                                                 |                                                 |
   |                                                             | INSERT INTO t VALUES (7,7,7,7); <br />(Blocked) |                                                 |
   |                                                             |                                                 | UPDATE t SET d=d+1 WHERE id=5;<br /> (Query OK) |
   |                                                             |                                                 | UPDATE t SET d=d+1 WHERE c=10;<br /> (Query OK) |

   session A用到了索引覆盖（只查询主键id），并且是加 s锁，所以无需回表对主键id加锁，加锁如下：
   session A持有的锁：`c:Next-Key Lock:(0,5]`+`c:Gap Lock:(5,10)`

2. 等值查询 – FOR UPDATE

   | session A                                           | session B                                      |
   | :-------------------------------------------------- | :--------------------------------------------- |
   | BEGIN; <br />SELECT id FROM t WHERE c=5 FOR UPDATE; |                                                |
   |                                                     | UPDATE t SET d=d+1 WHERE id=5; <br />(Blocked) |

   上一个例子中`LOCK IN SHARE MODE`只会锁住**覆盖索引**，而`FOR UPDATE`会同时给**聚簇索引**上**满足条件的行**加上**X Lock**，加锁如下：
   session A持有的锁：`c:Next-Key Lock:(0,5]`+`c:Gap Lock:(5,10)`+`PRIMARY:X Lock:5`

3. 等值查询 – 绕过覆盖索引

   | session A                                                 | session B                                      |
   | :-------------------------------------------------------- | :--------------------------------------------- |
   | BEGIN; <br />SELECT d FROM t WHERE c=5 LOCK IN SHARE MODE |                                                |
   |                                                           | UPDATE t SET d=d+1 WHERE id=5;<br /> (Blocked) |

   无法利用覆盖索引，就必须**回表**，与上面`FOR UPDATE`的情况一致，加锁如下：
   session A持有的锁：`c:Next-Key Lock:(0,5]`+`c:Gap Lock:(5,10)`+`PRIMARY:S Lock:5`

4. 等值查询 – 相同的值

   ```sql
   -- c=10有两行，两行之间也存在Gap
   INSERT INTO t VALUES (30,10,30,30);
   ```

   <img src="/images/mysql-lock//image-20210908144035137.png" alt="image-20210908144035137" style="zoom:80%;" />

   | session A                              | session B                                        | session C                                        |
   | :------------------------------------- | :----------------------------------------------- | :----------------------------------------------- |
   | BEGIN; <br />DELETE FROM t WHERE c=10; |                                                  |                                                  |
   |                                        | INSERT INTO t VALUES (12,12,12); <br />(Blocked) |                                                  |
   |                                        |                                                  | UPDATE t SET d=d+1 WHERE c=5;<br />(Query OK)    |
   |                                        |                                                  | UPDATE t SET d=d+1 WHERE c=15;<br />(Query OK)   |
   |                                        |                                                  | UPDATE t SET d=d+1 WHERE id=5; <br />(Query OK)  |
   |                                        |                                                  | UPDATE t SET d=d+1 WHERE id=15; <br />(Query OK) |
   |                                        |                                                  | UPDATE t SET d=d+1 WHERE id=10; <br />(Blocked)  |
   |                                        |                                                  | UPDATE t SET d=d+1 WHERE id=30;<br />(Blocked)   |

   <img src="/images/mysql-lock//image-20210908144122524.png" alt="image-20210908144122524" style="zoom:80%;" />

   session A持有的锁

   - `c:Next-Key Lock:((c=5,id=5),(c=10,id=10)]`+`c:Gap Lock:((c=10,id=10),(c=15,id=15))`
   - `PRIMARY:X Lock:10`+`PRIMARY:X Lock:30`

5. 等值查询 – LIMIT

   ```sql
   -- 与上面“相同的值”一样
   INSERT INTO t VALUES (30,10,30,30);
   ```

   | session A                                      | session B                                           | session C                                      |
   | :--------------------------------------------- | :-------------------------------------------------- | :--------------------------------------------- |
   | BEGIN; <br />DELETE FROM t WHERE c=10 LIMIT 2; |                                                     |                                                |
   |                                                | INSERT INTO t VALUES (12,12,12,12);<br />(Query OK) |                                                |
   |                                                |                                                     | UPDATE t SET d=d+1 WHERE id=10;<br />(Blocked) |
   |                                                |                                                     | UPDATE t SET d=d+1 WHERE id=30;<br />(Blocked) |

   在遍历到`(c=10,id=30)`这一行记录后，已经有两行记录满足条件，**循环结束**，session A在二级索引c上的加锁效果如下所示

   <img src="/images/mysql-lock//image-20210908151745952.png" alt="image-20210908151745952" style="zoom:90%;" />

   session A持有的锁

   - `c:Next-Key Lock:((c=5,id=5),(c=10,id=10)]`+`c:Next-Key Lock:((c=10,id=10),(c=10,id=30)]`
   - `PRIMARY:X Lock:10`+`PRIMARY:X Lock:30`

   因此在删除数据时，尽量加上`LIMIT`，可以**控制删除数据的条数**，也可以**减少加锁的范围**

6. 范围查询

   | session A                                                    | session B                                 | session C                                 |
   | :----------------------------------------------------------- | :---------------------------------------- | :---------------------------------------- |
   | BEGIN; <br />SELECT * FROM t WHERE c>=10 AND c<11 FOR UPDATE; |                                           |                                           |
   |                                                              | INSERT INTO t VALUES (8,8,8,8); (Blocked) |                                           |
   |                                                              |                                           | UPDATE t SET d=d+1 WHERE id=10; (Blocked) |
   |                                                              |                                           | UPDATE t SET d=d+1 WHERE c=15; (Blocked)  |

   由于二级索引`c`是**非唯一索引**，因此没法降级为**行锁**
   session A持有的锁

   - `c:Next-Key Lock:(5,10]`+`c:Next-Key Lock:(10,15]`
   - `PRIMARY:X Lock:10`

#### 无索引查询

```sql
begin;
select * from t where e = 10 for update;
```
RC：对所有记录加 Record Lock 再释放不匹配的记录锁
- MySQL 加锁时是对处理过程中“扫描”到的记录加锁，不管这条记录最终是不是通过 WHERE 语句剔除了
- 对于 READ COMMITTED，MySQL 在扫描结束后，会违反上条原则，释放 WHERE 条件不满足的记录锁
RR：通过聚簇索引，逐行扫描，逐行加锁，且索引前后都要加 Gap Lock，事务提交后统一释放锁

#### ORDER BY DESC

| session A                                                    | session B                                       |
| :----------------------------------------------------------- | :---------------------------------------------- |
| BEGIN;<br />SELECT * FROM t WHERE c>=15 AND c <=20 ORDER BY c DESC LOCK IN SHARE MODE; |                                                 |
|                                                              | INSERT INTO t VALUES (6,6,6);<br />(Blocked)    |
|                                                              | INSERT INTO t VALUES (21,21,21);<br />(Blocked) |
|                                                              | UPDATE t SET d=d+1 WHERE id=10;<br />(Query OK) |
|                                                              | UPDATE t SET d=d+1 WHERE id=25;<br />(Query OK) |
|                                                              | UPDATE t SET d=d+1 WHERE id=15;<br />(Blocked)  |
|                                                              | UPDATE t SET d=d+1 WHERE id=20;<br />(Blocked)  |

1. `ORDE BY DESC`，首先找到第一个满足`c=20`的行，session A持有锁：`c:Next-Key Lock:(15,20]`
2. 由于二级索引`c`是**非唯一索引**，继续向**右**遍历，session A持有锁：`c:Gap Key Lock:(20,25)`
3. 向**左**遍历，`c=15`，session A持有锁：`c:Next-Key Lock:(10,15]`
4. 继续向**左**遍历，`c=10`，session A持有锁：`c:Next-Key Lock:(5,10]`
5. 上述过程中，满足条件的主键为`id=15`和`id=20`，session A持有**聚簇索引**上对应行的`S Lock`
6. 总结，session A持有的锁
   - `c:Next-Key Lock:(5,10]`+`c:Next-Key Lock:(10,15]`+`c:Next-Key Lock:(15,20]`+`c:Gap Key Lock:(20,25)`
   - `PRIMARY:S Lock:15`+`PRIMARY:S Lock:20`

#### 等值 VS 遍历

```sql
BEGIN;
SELECT * FROM t WHERE id>12 AND id<18 ORDER BY id DESC FOR UPDATE;
```

1. 利用上面的加锁规则，加锁范围如下
   - `PRIMARY:Next-Key Lock:(5,10]`
   - `PRIMARY:Next-Key Lock:(5,15]`
   - `PRIMARY:Gap Lock:(15,20)`
2. 加锁动作是发生在语句执行过程中
   - `ORDER BY DESC`，优化器必须先找到**第一个id<18的值**
   - 这个过程是通过**索引树的搜索过程**得到的，其实是在引擎内部查找`id=18`
   - 只是最终没找到，而找到了`(15,20)`这个间隙
   - 然后**向左遍历**，在这个遍历过程，就不是等值查询了
   - 会扫描到 id=10 这一行，所以会加一个 next-key lock (5,10]
3. 在执行过程中，通过**树搜索**的方式定位记录的过程，用的是**等值查询**

#### IN

```sql
BEGIN;
SELECT id FROM t WHERE c IN (5,20,10) LOCK IN SHARE MODE;

-- Using index：使用了覆盖索引
-- key=c：使用了索引c
-- rows=3：三个值都是通过树搜索定位的
mysql> EXPLAIN SELECT id FROM t WHERE c IN (5,20,10) LOCK IN SHARE MODE;
+----+-------------+-------+------------+-------+---------------+------+---------+------+------+----------+--------------------------+
| id | select_type | table | partitions | type  | possible_keys | key  | key_len | ref  | rows | filtered | Extra                    |
+----+-------------+-------+------------+-------+---------------+------+---------+------+------+----------+--------------------------+
|  1 | SIMPLE      | t     | NULL       | range | c             | c    | 5       | NULL |    3 |   100.00 | Using where; Using index |
+----+-------------+-------+------------+-------+---------------+------+---------+------+------+----------+--------------------------
```

- 查找c=5：`c:Next-Key Lock:(0,5]`+`c:Gap Lock:(5,10)`

- 查找c=10：`c:Next-Key Lock:(5,10]`+`c:Gap Lock:(10,15)`

- 查找c=20：`c:Next-Key Lock:(15,20]`+`c:Gap Lock:(20,25)`

- 锁是在执行过程中是**一个一个**加的

1. ORDER BY DESC

   ```sql
   BEGIN;
   SELECT id FROM t WHERE c IN (5,20,10) ORDER BY c DESC FOR UPDATE;
   
   mysql> EXPLAIN SELECT id FROM t WHERE c IN (5,20,10) ORDER BY c DESC FOR UPDATE;
   +----+-------------+-------+------------+-------+---------------+------+---------+------+------+----------+-----------------------------------------------+
   | id | select_type | table | partitions | type  | possible_keys | key  | key_len | ref  | rows | filtered | Extra                                         |
   +----+-------------+-------+------------+-------+---------------+------+---------+------+------+----------+-----------------------------------------------+
   |  1 | SIMPLE      | t     | NULL       | range | c             | c    | 5       | NULL |    3 |   100.00 | Using where; Backward index scan; Using index |
   +----+-------------+-------+------------+-------+---------------+------+---------+------+------+----------+-----------------------------------------------+
   ```

   - `ORDER BY DESC`：先锁`c=20`，再锁`c=10`，最后锁`c=5`

   - **加锁资源相同**，但**加锁顺序相反**，如果语句是并发执行的，可能会出现**死锁**

### 死锁分析

#### 案例1：插入意向锁死锁案例

| trx_1                                                        | **trx_2**                                                    |
| ------------------------------------------------------------ | ------------------------------------------------------------ |
| start transaction;                                           |                                                              |
|                                                              | start transaction;                                           |
| update t set e = 1 where c = 5;<br />索引c上加(0,5] next-key 、(5,10) gap |                                                              |
|                                                              | update t set e = 1 where c = 5; <br />因为加锁是一个动态过程，首先加gap锁 (0,5)，因为gap锁兼容，所以可以获取到这个gap锁<br />当扫描到c=5这行时，需要加行锁，但是此行锁已经在被事务1获取，所以无法获取到行锁，<br />所以事务2需要等待事务1释放锁，所以产生锁等待 |
| insert into t set id = 4, c = 5;<br />插入语句会产生插入意向锁，会判断是否存在(0,5)gap、(0,5] next-key，<br />因为事务2持有(0,5)gap，如果需要插入成功，需要事务2释放(0,5)gap，<br />但是事务2又在等待事务1释放 c=5行锁，因此产生了环形等待，即死锁，所以触发事务2回滚 | ERROR 1213 (40001): Deadlock found when trying to get lock; try restarting transaction |

## 分析死锁日志

- 死锁场景：

| session A                                                    | session B                               |
| ------------------------------------------------------------ | --------------------------------------- |
| BEGIN;                                                       |                                         |
| SELECT id FROM t WHERE c=5 LOCK IN SHARE MODE;               |                                         |
|                                                              | BEGIN;                                  |
|                                                              | SELECT id FROM t WHERE c=20 FOR UPDATE; |
| SELECT id FROM t WHERE c=20 LOCK IN SHARE MODE;              |                                         |
|                                                              | SELECT id FROM t WHERE c=5 FOR UPDATE;  |
| Deadlock found when trying to get lock; try restarting transaction |                                         |

MySQL只保留**最后一个死锁的现场**，并且这个现场还不完备

```sql
mysql> SHOW ENGINE INNODB STATUS\G;
*** (1) TRANSACTION:
TRANSACTION 421596638701408, ACTIVE 23 sec starting index read
mysql tables in use 1, locked 1
LOCK WAIT 4 lock struct(s), heap size 1136, 3 row lock(s)
MySQL thread id 2, OS thread handle 140121299891968, query id 964 172.17.0.1 root Sending data
SELECT id FROM t WHERE c=20 LOCK IN SHARE MODE
*** (1) WAITING FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS space id 39 page no 5 n bits 80 index c of table `test`.`t` trx id 421596638701408 lock mode S waiting
Record lock, heap no 6 PHYSICAL RECORD: n_fields 2; compact format; info bits 0
 0: len 4; hex 80000014; asc     ;;
 1: len 4; hex 80000014; asc     ;;

*** (2) TRANSACTION:
TRANSACTION 8656, ACTIVE 14 sec starting index read
mysql tables in use 1, locked 1
5 lock struct(s), heap size 1136, 4 row lock(s)
MySQL thread id 5, OS thread handle 140121299080960, query id 968 172.17.0.1 root Sending data
SELECT id FROM t WHERE c=5 FOR UPDATE
*** (2) HOLDS THE LOCK(S):
RECORD LOCKS space id 39 page no 5 n bits 80 index c of table `test`.`t` trx id 8656 lock_mode X
Record lock, heap no 6 PHYSICAL RECORD: n_fields 2; compact format; info bits 0
 0: len 4; hex 80000014; asc     ;;
 1: len 4; hex 80000014; asc     ;;

*** (2) WAITING FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS space id 39 page no 5 n bits 80 index c of table `test`.`t` trx id 8656 lock_mode X waiting
Record lock, heap no 3 PHYSICAL RECORD: n_fields 2; compact format; info bits 0
 0: len 4; hex 80000005; asc     ;;
 1: len 4; hex 80000005; asc     ;;

*** WE ROLL BACK TRANSACTION (1)
```

- `(1) TRANSACTION`：第一个事务的信息
- `(2) TRANSACTION`：第二个事务的信息
- `WE ROLL BACK TRANSACTION (1)`：最终的处理结果是回滚第一个事务

#### 第一个事务

```sql
SELECT id FROM t WHERE c=20 LOCK IN SHARE MODE
*** (1) WAITING FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS space id 39 page no 5 n bits 80 index c of table `test`.`t` trx id 421596638701408 lock mode S waiting
Record lock, heap no 6 PHYSICAL RECORD: n_fields 2; compact format; info bits 0
 0: len 4; hex 80000014; asc     ;;
 1: len 4; hex 80000014; asc     ;;
```

1. `(1) WAITING FOR THIS LOCK TO BE GRANTED`：表示第一个事务在等待的锁的信息
2. `index c of table test.t`：表示等待表`t`的索引`c`上的锁
3. `lock mode S waiting`：表示正在执行的语句要加一个`S Lock`，当前状态为**等待中**
4. `Record lock`：表示这是一个**记录锁**（行数）
5. `n_fields 2`：表示这个记录有2列（二级索引），即字段`c`和主键字段`id`
6. `len 4; hex 80000014; asc ;;`：第一个字段`c`
   - `asc`：表示接下来要打印值里面的**可打印字符**，20不是可打印字符，因此显示**空格**
7. `1: len 4; hex 80000014; asc ;;`：第二个字段`id`
8. 第一个事务在等待`(c=20,id=20)`这一行的行锁
9. 但并没有打印出第一个事务本身所占有的锁，可以通过第二个事务反向推导出来

#### 第二个事务

```sql
SELECT id FROM t WHERE c=5 FOR UPDATE
*** (2) HOLDS THE LOCK(S):
RECORD LOCKS space id 39 page no 5 n bits 80 index c of table `test`.`t` trx id 8656 lock_mode X
Record lock, heap no 6 PHYSICAL RECORD: n_fields 2; compact format; info bits 0
 0: len 4; hex 80000014; asc     ;;
 1: len 4; hex 80000014; asc     ;;

*** (2) WAITING FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS space id 39 page no 5 n bits 80 index c of table `test`.`t` trx id 8656 lock_mode X waiting
Record lock, heap no 3 PHYSICAL RECORD: n_fields 2; compact format; info bits 0
 0: len 4; hex 80000005; asc     ;;
 1: len 4; hex 80000005; asc     ;;
```

1. `(2) HOLDS THE LOCK(S)`：表示第二个事务持有的锁的信息
2. `index c of table test.t`：表示锁是加在表`t`的索引`c`上
3. `0: len 4; hex 80000014; asc ;;`+`1: len 4; hex 80000014; asc ;;`
   - 第二个事务持有`(c=20,id=20)`这一行的行锁（`X Lock`）
4. `(2) WAITING FOR THIS LOCK TO BE GRANTED`
   - 第二个事务等待`(c=5,id=5)`只一行的行锁
