cmake_minimum_required(VERSION 3.10)
project(mastream LANGUAGES CXX)
add_library(mastream
  SHARED
  ./ma_stream.cc
)
