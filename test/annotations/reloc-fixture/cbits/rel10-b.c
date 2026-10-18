static volatile int local_value = 29;

int rel10_read_b(void)
{
    return local_value;
}
