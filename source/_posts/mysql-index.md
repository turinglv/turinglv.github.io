---
title: MySQL -- 索引
date: 2020-01-15
categories:
    - Storage
    - MySQL
tags:
    - Storage
    - MySQL
typora-root-url: ../../source

---

## 索引模型

### 哈希表

键 - 值（key-value）存储数据的结构，类似java的HashMap

<img src="/images/mysql-index/0c62b601afda86fe5d0fe57346ace957.png" alt="img" style="zoom:50%;" />

**哈希表这种结构适用于只有等值查询的场景，比如 Memcached 及其他一些 NoSQL 引擎**

### 有序数组

**有序数组索引只适用于静态存储引擎**，比如你要保存的是 2017 年某个城市的所有人口信息，这类不会再修改的数据

<img src="/images/mysql-index/bfc907a92f99cadf5493cf0afac9ca49.png" alt="img" style="zoom:50%;" />

#### 查找
1. 等值查询：可以采用**二分法**，时间复杂度为`O(log(N))`
2. 范围查询：查找`[ID_card_X,ID_card_Y]`
   - 首先通过**二分法**找到第一个大于等于`ID_card_X`的记录
   - 然后向**右**遍历，直到找到第一个大于`ID_card_Y`的记录

#### 插入
往中间插入一个记录就必须得挪动后面所有的记录，成本很高，所以只适用于存储静态数据

### 搜索树

#### 平衡二叉树
查询的时间复杂度：`O(log(N))`，更新的时间复杂度：`O(log(N))`（维持树的**平衡**）

<img src="/images/mysql-index/04fb9d24065635a6a637c25ba9ddde68.png" alt="img" style="zoom:50%;" />

## InnoDB索引模型

使用B+树作为索引模型

### **B+树数据结构**
   - B+树是 B 树的一种变形形式，B+树上的叶子结点存储关键字以及相应记录的地址，叶子结点以上各层作为索引使用
   - 一棵 m 阶的 B+树定义如下（***B+树的阶数 m 表示一个节点最多能有 m 个子节点,也就是每个节点上最多有m-1的关键字***）
     - 每个结点至多有 m 个子节点
     - 除根结点外，每个结点至少有[m/2]个子节点，根结点至少有两个子节点
     - 有 k 个子节点的结点必有 k 个关键字
   - B+树的查找与 B 树不同，当索引部分某个结点的关键字与所查的关键字相等时，并不停止查找，应继续沿着这个关键字左边的指针向下，一直查到该关键字所在的叶子结点为止

###  **MySQL B+树索引有多少阶**
   - 对于这个问题,我们需要先了解下磁盘相关知识.
     - 磁盘的最小存储单位是扇区(512 字节)
     - 磁盘的读取是以块为基本单位,一块大小为 8 个扇区,即 4kb
     - B+树的每一个节点占用的空间就是一个mysql页大小

   <img src="/images/mysql-index/bc946b22c5275a1293f7be8902edb256.png" alt="img" style="zoom:60%;" />

   - 以 innodb 引擎的索引数据结构为例,它的存储单元为一页,每页大小默认为 16KB
     - 假设每个节点中索引元素占 8 个字节,指针占用 6 个字节,那么每页可存(16*1024)/(8+6)=1170 个索引元素
     - 假设 B+树的高度为 3,一条数据大小为 1k,那么:第一层可以存 1170 个元素;第二层可以存 1170 * 1170=1368900 个元素;第三层属于叶子结点,可以存的数据条数为页大小 16KB / 每条数据大小 1KB,即 16 条,那么总共可以存储的数据条数即为 16*1368900=21902400

### **MySQL 索引组织表**
   在 InnoDB 中，表都是根据**主键顺序**以索引的形式存放的，这种存储方式的表称为**索引组织表**，每一个**索引**在InnoDB里面都对应一棵**B+树**

   ```sql
   # 建表
   CREATE TABLE T(
       id INT PRIMARY KEY,
       k INT NOT NULL,
       INDEX (k)
   ) ENGINE=INNODB;
   
   # 初始化数据
   R1 : (100,1)
   R2 : (200,2)
   R3 : (300,3)
   R4 : (500,5)
   R5 : (600,6)
   ```

   <img src="/images/mysql-index/dcda101051f28502bd5c4402b292e38d.png" alt="img" style="zoom:60%;" />

   1. 根据叶子节点的内容，索引类型分为聚簇索引（clustered index）和二级索引（secondary index）
      - 聚簇索引的叶子节点存储的是**整行数据**
      - 二级索引的叶子节点存储的是**主键的值**
   2. `select * from T where ID=500`：只需要搜索ID树
   3. `select * from T where k=5`：先搜索k树，得到ID的值为500，再到ID树搜索，该过程称为***回表***
   4. 基于二级索引的查询需要多扫描一棵索引树，因此**尽量使用主键查询**

### **索引维护**
   1. B+树为了维护**索引的有序性**，在插入新值时，需要做必要的维护
   2. 如果新插入的行ID为700，只需要在R5的记录后插入一个新纪录
   3. 如果新插入的行ID为400，需要逻辑上（实际采用链表的形式，直接追加）挪动R3后面的数据，空出位置
      - 如果R5所在的数据页已经满了，根据B+树的算法，需要申请一个新的数据页，然后将部分数据挪过去，称为***页分裂***
      - 页分裂的影响：**性能**、**数据页的利用率**
   4. 页合并：页分裂的逆过程
      - 当**相邻**两个页由于**删除**了数据，利用率很低之后，会将数据页合并

### **索引重建**

   ```sql
   # 重建二级索引
   ALTER TABLE T DROP INDEX k;
   ALTER TABLE T ADD INDEX(k);
   
   # 重建聚簇索引
   ALTER TABLE T DROP PRIMARY KEY;
   ALTER TABLE T ADD PRIMARY KEY(id);
   ```

   1. 重建索引的原因
      - 索引可能因为**删除和页分裂**等原因，导致**数据页有空洞**
      - 重建索引的过程会**创建一个新的索引**，**把数据按顺序插入**
      - 这样**页面的利用率最高**，使得索引更紧凑，更省空间
   2. 重建二级索引k是合理的，可以达到省空间的目的
   3. 重建聚簇索引是不合理的
      - 不论是**删除聚簇索引**还是**创建聚簇索引**，都会**将整个表重建**
      - 替代语句：`ALTER TABLE T ENGINE=INNODB`

### **自增主键**
   1. 逻辑：如果主键为自增，并且在插入新纪录时不指定主键的值，系统会获取当前主键的最大值+1作为新纪录的主键
      - 适用于**递增插入**的场景，每次插入一条新纪录都是**追加操作**，既不会涉及其他记录的挪动操作，也不会触发页分裂
   2. 如果采用**业务字段**作为主键，**很难保证有序插入**，写数据的成本相对较高
   3. 主键长度越小，二级索引占用的空间也就越小
      - 在一般情况下，创建一个自增主键，这样二级索引占用的空间最小
   4. 针对实际中一般采用分布式ID生成器的情况
      - 满足**有序插入**
      - 分布式ID**全局唯一**
   5. 适合直接采用业务字段做主键的场景：KV场景（只有一个唯一索引）
      - 无须考虑**二级索引的占用空间问题**
      - 无须考虑**二级索引的回表问题**

## 索引优化

### 覆盖索引

```sql
# 建表
CREATE TABLE T (
    ID INT PRIMARY KEY,
    k INT NOT NULL DEFAULT 0,
    s VARCHAR(16) NOT NULL DEFAULT '',
    INDEX k(k)
) ENGINE=INNODB;

# 初始化数据
INSERT INTO T VALUES (100,1,'aa'),(200,2,'bb'),(300,3,'cc'),(500,5,'ee'),(600,6,'ff'),(700,7,'gg');
```

<img src="/images/mysql-index/mysql-index-scan-row.png" alt="img" style="zoom:45%;" />

#### 需要回表的查询

```sql
SELECT * FROM T WHERE k BETWEEN 3 AND 5
```

1. 在k树上找到k=3的记录，取得ID=300
2. 再到ID树上查找ID=300的记录，对应为R3
3. 在k树上取**下一个**值k=5，取得ID=500
4. 再到ID树上查找ID=500的记录，对应为R4
5. 在k树上取**下一个**值k=6，不满足条件，循环结束

整个查询过程读了k树3条记录，回表了2次

#### 不需要回表的查询

```sql
SELECT ID FROM T WHERE k BETWEEN 3 AND 5
```

1. 只需要查ID的值，而ID的值已经在k树上，可以直接提供查询结果，不需要回表
   - 因为k树已经覆盖了我们的查询需求，因此称为**覆盖索引**
2. 覆盖索引可以**减少树的搜索次数**，显著**提升查询性能**，因此使用覆盖索引是一个常用的性能优化手段
3. 扫描行数
   - 在存储引擎内部使用覆盖索引在索引k上其实是读取了3个记录，
   - 但对于MySQL的**Server层**来说，存储引擎返回的只有2条记录，因此MySQL认为扫描行数为2

#### 联合索引

```sql
CREATE TABLE `tuser` (
    `id` INT(11) NOT NULL,
    `id_card` VARCHAR(32) DEFAULT NULL,
    `name` VARCHAR(32) DEFAULT NULL,
    `age` INT(11) DEFAULT NULL,
    `ismale` TINYINT(1) DEFAULT NULL,
    PRIMARY KEY (`id`),
    KEY `id_card` (`id_card`),
    KEY `name_age` (`name`,`age`)
) ENGINE=InnoDB
```

高频请求：根据id_card查询name。可以建立联合索引`(id_card,name)`，达到**覆盖索引**的效果

### 最左前缀原则

B+树的索引结构，可以利用索引的**最左前缀**来定位记录

<img src="/images/mysql-index/mysql-index-leftmost-prefix.jpg" alt="img" style="zoom:45%;" />

1. 索引项是按照索引定义里字段出现的顺序来排序的
   - 如果查找所有名字为**张三**的人时，可以快速定位到ID4，然后**向后遍历**，直到不满足条件为止
   - 如果查找所有名字的第一个字是**张**的人，找到第一个符合条件的记录ID3，然后**向后遍历**，直到不满足条件为止
2. 只要满足最左前缀，就可以利用索引来加速检索，最左前缀有2种情况
   - **联合索引的最左N个字段**
   - **字符串索引的最左M个字符**
3. 建立联合索引时，定义索引内字段顺序的原则
   - **复用**：如果通过调整顺序，可以**少维护一个索引**，往往优先考虑这样的顺序
   - **空间**：维护`(name,age)`+`age`比维护`(age,name)`+`name`所占用的空间更少

### 索引下推

```sql
SELECT * FROM tuser WHERE name LIKE '张%' AND age=10 AND ismale=1;
```

1. 依据**最左前缀**原则，上面的查询语句只能用**张**，找到第一个满足条件的记录ID3（优于全表扫描）
2. 然后判断其他条件是否满足
   - 在MySQL 5.6之前，只能从ID3开始一个个回表，到聚簇索引上找出对应的数据行，再对比字段值
     - 这里暂时忽略**MRR**：在不影响排序结果的情况下，在取出主键后，回表之前，会对所有获取到的主键进行排序
   - 在MySQL 5.6引入了下推优化（index condition pushdown）
     - 可以在**索引遍历**过程中，**对索引所包含的字段先做判断**，**直接过滤掉不满足条件的记录**，**减少回表次数**

无索引下推，回表4次

<img src="/images/mysql-index/mysql-index-pushdown.jpg" alt="img" style="zoom:45%;" />

采用索引下推，回表2次

<img src="/images/mysql-index/mysql-index-no-pushdown.jpg" alt="img" style="zoom:45%;" />

### 删除冗余索引

```sql
CREATE TABLE `geek` (
    `a` int(11) NOT NULL,
    `b` int(11) NOT NULL,
    `c` int(11) NOT NULL,
    `d` int(11) NOT NULL,
    PRIMARY KEY (`a`,`b`),
    KEY `c` (`c`),
    KEY `ca` (`c`,`a`),
    KEY `cb` (`c`,`b`)
) ENGINE=InnoDB;

# 索引(`a`,`b`)是业务属性
# 常规查询，应该如何优化索引？
select * from geek where c=N order by a limit 1;
select * from geek where c=N order by b limit 1;
```
索引`ca`是不需要的，因为满足**最左前缀**原则，`ca(b) = c(ab)`

## 参考资料
《MySQL实战45讲》
http://zhongmingmao.me/2019/01/21/mysql-index/
