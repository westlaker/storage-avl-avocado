  sudo apt-get update && sudo apt-get install -y build-essential cmake git     libsnappy-dev zlib1g-dev libbz2-dev liblz4-dev libzstd-dev
  git clone --depth=1 https://github.com/facebook/rocksdb.git && cd rocksdb
  make -j2 static_lib db_bench
  sudo cp db_bench /usr/local/bin/

