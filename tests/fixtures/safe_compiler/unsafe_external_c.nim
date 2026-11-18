{.passC: "-DTEST_EXTERNAL_C=1".}

proc main() =
  echo "external C pragma should be rejected"

main()
