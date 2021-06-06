---
title: MySQL -- 事务隔离
date: 2020-01-10
categories:
    - Storage
    - MySQL
tags:
    - Storage
    - MySQL
typora-root-url: ../../source

---

## 事务概念
- 事务就是要保证一组数据库操作，要么全部成功，要么全部失败
- MySQL 中，事务支持是在引擎层实现的
  - MyISAM不支持事务
  - InnoDB支持事务

## 隔离性与隔离级别
- 事务特性：**ACID**（Atomicity、Consistency、Isolation、Durability）
  - Atomicity（原子性）：事务的所有操作，要么全部完成，要么全部不完成，不会结束在某个中间环节
    - 事务commit，MySQL crash或者系统宕机，可以通过redolog崩溃恢复
    - 事务rollback，通过undolog进行数据恢复
  - Consistency（一致性）：事务开始之前和事务结束之后，数据库的完整性限制未被破坏
    - 事务的一致性就是在事务定义层级（数据库、应用层、甚至多个应用）里，用AID特性和回滚手段满足了该层级的约束，即可满足该层级的C
  - Isolation（隔离性）：每个读写事务的对象对其他事务的操作对象能相互隔离，即该事务提交前对其他事务都不可见
    - 通过MVCC、锁实现
  - Durability（持久性）：事务处理结束后，对数据的修改就是永久的，即便系统故障也不会丢失
    - 通过redolog实现
- 数据库上有多个事务同时执行的时候，就可能出现**脏读（dirty read）、不可重复读（non-repeatable read）、幻读（phantom read）**的问题
  - 解决方案：**隔离级别**
  - 隔离级别越高，效率就会越低
  - 脏读：读到其他事务未提交的数据
  - 不可重复读：前后读取的记录内容不一致 
  - 幻读：前后读取的记录数量不一致
- SQL的标准隔离级别：
  - **READ-UNCOMMITTED（读未提交）**
    - 一个事务还未提交时，它所做的变更能被别的事务看到
  - **READ-COMMITTED（读已提交）**
    - 一个事务提交之后，它所做的变更才会被其他事务看到
  - **REPEATABLE-READ（可重复读）**
    - 一个事务在执行过程中所看到的数据，总是跟这个事务在启动时看到的数据是一致的
    - 同样，在RR隔离级别下，未提交的变更对其他事务也是不可见的
  - **SERIALIZABLE（串行化）**
    - 对同一行记录，写会加写锁，读会加读锁，锁级别是**行锁**
    - 当出现读写锁冲突时，后访问的事务必须等前一个事务执行完成，才能继续执行
```sql
mysql> SHOW VARIABLES LIKE '%isolation%';
+---------------+-----------------+
| Variable_name | Value           |
+---------------+-----------------+
| tx_isolation  | REPEATABLE-READ |
+---------------+-----------------+
```

## 隔离级别数据形态
```sql
mysql> create table T(c int) engine=InnoDB;
insert into T(c) values(1);
```
<img src="/images/mysql-transaction-isolation/7dea45932a6b722eb069d2264d0066f8.png" alt="img" style="zoom:45%;" />

| 隔离级别         | V1   | V2   | V3   | 实现方式                                                     |
| :--------------- | :--- | :--- | :--- | :----------------------------------------------------------- |
| READ-UNCOMMITTED | 2    | 2    | 2    | **没有read-view概念**，直接返回**记录上的最新值**（**内存**，InnoDB Buffer Pool） |
| READ-COMMITTED   | 1    | 2    | 2    | **每个SQL语句开始执行时**创建**read-view**，根据read-view读取数据 |
| REPEATABLE-READ  | 1    | 1    | 2    | **事务启动时**创建**read-view**，整个事务存在期间都用这个read-view，根据read-view读取数据 |
| SERIALIZABLE     | 1    | 1    | 2    | 用**加锁**（行锁）的方式来避免并行访问                       |

## Read View
### 概念
InnoDB支持MVCC多版本，其中RC（Read Committed）和RR（Repeatable Read）隔离级别是利用consistent read view（一致读视图）方式支持的。 所谓consistent read view就是在某一时刻给事务系统trx_sys打snapshot（快照），把当时trx_sys状态（包括活跃读写事务数组）记下来，之后的所有读操作根据其事务ID（即trx_id）与snapshot中的trx_sys的状态作比较，以此判断read view对于事务的可见性
### 主要结构
- **m_low_limit_id（低水位）**：活跃事务列表里面**最小的事务ID**
- **m_up_limit_id（高水位）**：当前系统已经创建的事务id的最大值+1（**并不是数组内的最大**）
- **m_creator_trx_id（视图创建事务ID）**：创建该ReadView的事务，该事务ID的数据修改可见。
- **m_ids（活跃事务ID）**：当快照创建时的活跃读写事务列表
- **m_low_limit_no（事务number）**：事务number，事务提交时候获取同时写入Undo log中的值。事务number小于该值的对该ReadView不可见。利用该信息可以Purge不需要的Undo
- **m_closed**： 标记该ReadView closed，用于优化减少trx_sys->mutex这把大锁的使用。可以看到在view_close的时候如果是在不持有trx_sys->mutex锁的情况下，会仅将ReadView标记为closed，并不会把ReadView从m_views的list中移除

<img src="/images/mysql-transaction-isolation/882114aaf55861832b4270d44507695e.png" alt="img" style="zoom:45%;" />

- **行隐藏列**
  - RowID：隐藏的自增ID，当建表没有指定主键，InnoDB会使用该RowID创建一个聚簇索引
  - DB_TRX_ID：最近修改（更新/删除/插入）该记录的事务ID
  - DB_ROLL_PTR：回滚指针，指向这条记录的上一个版本

### 可见性判断
- 如果记录trx_id小于m_up_limit_id或者等于m_creator_trx_id，表明ReadView创建的时候该事务已经提交，记录可见
- 如果记录的trx_id大于等于m_low_limit_id，表明事务是在ReadView创建后开启的，其修改，插入的记录不可见
- 当记录的trx_id在m_up_limit_id和m_low_limit_id之间的时候
  - 如果id在m_ids数组中，表明ReadView创建时候，事务处于活跃状态，因此记录不可见
  - 如果id不在m_ids数组中，表明ReadView创建时候，事务已经提交，因此记录可见

### 版本链
- 在InnoDB，每个事务都有一个唯一的事务ID（transaction id）
  - 在**事务开始**的时候向InnoDB的**事务系统**申请的，**按申请的顺序严格递增**
- 每行数据都有多个版本，每次事务更新数据的时候，都会生成一个新的数据版本
  - 事务会把自己的transaction id赋值给这个数据版本的事务ID，记为`row trx_id`
    - **每个数据版本都有对应的row trx_id**
  - 同时也要**逻辑保留**旧的数据版本，通过新的数据版本和`undolog`可以**计算**出旧的数据版本
  <img src="/images/mysql-transaction-isolation/mysql-innodb-row-multi-version-20210606133912235.png" alt="img" style="zoom:45%;" />
- 虚线框是同一行记录的4个版本
- 当前最新版本为V4，k=22，是被`transaction id`为25的事务所更新的，因此它的`row trx_id`为25虚线箭头就是undolog，而V1、V2和V3并不是物理真实存在的
  - 每次需要的时候根据**当前最新版本**与`undolog`计算出来的
  - 例如当需要V2时，就通过V4依次执行U3和U2算出来的

## RR隔离的实现
每条记录在**更新**的时候都会同时（**在redolog和binlog提交之前**）记录一条**回滚操作**记录上的最新值，通过回滚操作，都可以得到前一个状态的值

## 事务启动
1. `BEGIN/START TRANSACTION`：事务**并未立马启动**，在执行到后续的第一个**一致性读**语句，事务才真正开始
2. `START TRANSACTION WITH CONSISTENT SNAPSHOT;`：事务**立马启动**

## 执行分析
**例子中如果没有特别说明，都是默认 autocommit=1**
### 初始化表

```sql
# 建表
CREATE TABLE `t` (
    `id` INT(11) NOT NULL,
    `k` INT(11) DEFAULT NULL,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB;

# 表初始化
INSERT INTO t (id, k) VALUES (1,1), (2,2);
```
### Demo-1
<img src="/images/mysql-transaction-isolation/823acf76e53c0bdba7beab45e72e90d6.png" alt="img" />

#### 事务A查询  

- **假设**
  - 事务A开始前，系统里只有一个活跃事务ID是99
  - 事务ABC的事务ID分别是100，101和102，且当前系统只有这4个事务
  - 事务ABC开始前，`(1,1)`这一行数据的`row trx_id`是90
  - 视图数组
    - 事务A：`[99,100]`
    - 事务B：`[99,100,101]`
    - 事务C：`[99,100,101,102]`
  - 低水位与高水位
    - 事务A：`99`和`100`
    - 事务B：`99`和`101`
    - 事务C：`99`和`102`
  
- **查询逻辑**
  
  <img src="/images/mysql-transaction-isolation/86ad7e8abe7bf16505b97718d8ac149f.png" alt="img" style="zoom:50%;" />
  
  第一个有效更新是事务C，采用当前读，读取当前最新版本`(1,1)`，改成`(1,2)`
  - 此时最新版本的`row trx_id`为102，90那个版本成为历史版本
    - 由于**autocommit=1**，事务C在执行完更新后会立马**释放**id=1的**行锁**
  - 第二个有效更新是事务B，采用当前读，读取当前最新版本`(1,2)`，改成`(1,3)`
    - 此时最新版本的`row trx_id`为101，102那个版本成为历史版本
  - 事务A查询时，由于事务B还未提交，当前最新版本为`(1,3)`，对事务A是不可见的，否则就了脏读了，读取过程如下
    - 事务A的视图数组为`[99,100]`，读数据都是从**当前最新版本**开始读
    - 首先找到当前最新版本`(1,3)`，判断`row trx_id`为101，比事务A的视图数组的高水位（100）大，**不可见**
    - 接着寻找**上一历史版本**，判断`row trx_id`为102，同样比事务A的视图数组的高水位（100）大，**不可见**
    - 再往前寻找，找到版本`(1,1)`，判断`row trx_id`为90，比事务A的视图数组的低水位（99）小，**可见**
    - 所以事务A的查询结果为1
  - **一致性读**：事务A不论在什么时候查询，看到的数据都是**一致**的，哪怕同一行数据同时会被其他事务更新
  
- ##### 时间视角
  - 一个数据版本，对于一个事务视图来说，除了该事务本身的更新总是可见以外，还有下面3种情况
     - 如果版本对应的事务未提交，不可见
     - 如果版本对应的事务已提交，但是是在视图创建之后提交的，不可见
     - **如果版本对应的事务已提交，并且是在视图创建之前提交的，可见**
  - 归纳：***一个事务只承认自身更新的数据版本以及视图创建之前已经提交的数据版本***
  - 应用规则进行分析
     - 事务A的**一致性读视图**是在事务A启动时生成的，在事务A查询时
     - 此时`(1,3)`的数据版本尚未提交，不可见
     - 此时`(1,2)`的数据版本虽然提交了，但是是在事务A的**一致性读视图**创建之后提交的，不可见
     - 此时`(1,1)`的数据版本是在事务A的**一致性读视图**创建之前提交的，可见
  
- **更新逻辑**

  <img src="/images/mysql-transaction-isolation/86ad7e8abe7bf16505b97718d8ac149f.png" alt="img" style="zoom:50%;" />

  - 可能会产生的疑问：  
    - 事务 B 的视图数组是先生成的，之后事务 C 才提交，不是应该看不见 (1,2) 吗，怎么能算出 (1,3) ？
    - 如果事务 B 在更新之前查询一次数据，这个查询返回的 k 的值确实是 1，但是，当它要去更新数据的时候，**不能再在历史版本上更新**，否则事务 C 的更新就丢失了
  - 更新数据需要先进行**当前读**（current read），再写入数据
    - ***当前读：总是读取已经提交的最新版本***
    - **当前读伴随着加锁**（更新操作为**X Lock模式的当前读**）
    - 如果当前事务在执行当前读时，其他事务在这之前已经执行了更新操作，但尚未提交（**持有行锁**），当前事务被阻塞
  - 事务B的`SET k=k+1`操作是在最新版`(1,2)`上进行的，更新后生成新的数据版本`(1,3)`，对应的`row trx_id`为101
  - 事务B在进行后续的查询时，发现最新的数据版本为`101`，与自己的版本号**一致**，认可该数据版本，查询结果为3
  - 当前读

    ```sql
    # 查询语句
    ## 读锁（S锁，共享锁）
    SELECT k FROM t WHERE id=1 LOCK IN SHARE MODE;
    ## 写锁（X锁，排他锁）
    SELECT k FROM t WHERE id=1 FOR UPDATE;
    
    # 更新语句，首先采用（X锁的）当前读
    ```
### Demo-2
假设事务 C 不是马上提交的，而是变成了下面的事务 C’
<img src="/images/mysql-transaction-isolation/cda2a0d7decb61e59dddc83ac51efb6e.png" />

<img src="/images/mysql-transaction-isolation/540967ea905e8b63630e496786d84c92.png" alt="img" style="zoom:50%;" />

- 事务C’没有自动提交，依然持有当前最新版本版本`(1,2)`上的**写锁**（X Lock）
- 事务B执行更新语句，采用的是**当前读**（X Lock模式），会被阻塞，必须等事务C’释放这把写锁后，才能继续执行

## RR & RC

### RR
- RR的实现核心为**一致性读**（consistent read）
- 事务更新数据的时候，只能用**当前读**（current read）
- 如果当前的记录的行锁被其他事务占用的话，就需要进入**锁等待**
- 在RR隔离级别下，只需要在事务**启动**时创建一致性读视图，之后事务里的其他查询都共用这个一致性读视图
- 对于RR，查询只承认**事务启动前**就已经提交的数据
- 表结构不支持RR，只支持当前读
  - 因为表结构没有对应的行数据，也没有row trx_id

### RC
- 在RC隔离级别下，每个**语句执行前**都会**重新计算**出一个新的一致性读视图
- 在RC隔离级别下，再来考虑Demo1，事务A与事务B的查询语句的结果
- `START TRANSACTION WITH CONSISTENT SNAPSHOT`的原意：创建一个持续整个事务的一致性视图
  - 在RC隔离级别下，一致性读视图会被**重新计算**，等同于普通的`START TRANSACTION`
- 事务A的查询语句的一致性读视图是在执行这个语句时才创建的
  - 数据版本`(1,3)`未提交，不可见
  - 数据版本`(1,2)`提交了，并且在事务A**当前的一致性读视图**创建之前提交的，**可见**
  - 因此事务A的查询结果为2
- 事务B的查询结果为3
- 对于RC，查询只承认**语句启动前**就已经提交的数据

<img src="/images/mysql-transaction-isolation/mysql-innodb-trx-rc-20210606162844432.png" alt="img" style="zoom:50%;" />
